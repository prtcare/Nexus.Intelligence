using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Gateway;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Turns;
using Nexus.Intelligence.Tests.Operations;
using Nexus.Intelligence.Tests.Turns;
using Nexus.Platform.Contracts.Tools;
using Xunit;
using static Nexus.Intelligence.Tests.Operations.W7eFixture;

namespace Nexus.Intelligence.Tests.Gateway;

// W7G-R TASK 5: the degraded-mode proofs, one per dependency class.
//
// WHY THIS FILE EXISTS AT ALL. The estate has four dependency classes and, before this file, the
// end-to-end behaviour behind each of the three non-prohibited ones was unproved. What existed was
// declaration-level coverage - W7A rejects a malformed declaration, W7B proves an AiProhibited
// capability is refused - and two gateway tests about the caller's own degradation preference. What
// did not exist was any test that asked the question the class is a statement about: with the AI Head
// unavailable, what does a caller of THIS class receive?
//
// WHAT THE TESTS FOUND, AND WHY THE ASSERTIONS ARE SHAPED THE WAY THEY ARE. Three of the four classes
// are operationally indistinguishable, and that is not an omission in the estate - it is the design,
// stated in AiDependencyRegistry's own remarks ("nothing here is consulted when serving a request")
// and in AiDependencyClass's ("a statement about authority"). The class is a declaration that says
// what a caller OUGHT to do; the caller's AiExecutionPolicy.OnDegradation is what it actually does.
// So the assertions below are deliberately written as PAIRS: the same class under two policies, and
// two classes under one policy. A test that asserted only "AiOptional degrades" would pass on an
// estate that degraded everything, which is why the identity of the two answers is asserted rather
// than described.
//
// Two findings are recorded rather than fixed, both proved below and both documented in
// W7G_DEGRADED_MODE.md: the availability gate answers before governance, so a prohibited capability
// under an outage is reported as an outage; and a dependent capability under the default policy is
// labelled degraded although its declaration says it has no deterministic path to degrade to.
public sealed class W7gDegradedModeTests
{
    // ---------------------------------------------------------------------------------------------
    // A. The directive's headline: an AI outage must not crash anything, and must not stop the
    //    functions that have nothing to do with AI.
    // ---------------------------------------------------------------------------------------------

    /// <summary>
    /// Every dependency class answers a request made during an outage, and none of them throws.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The directive's clause is "AI unavailable must not crash unrelated Product/Platform functions",
    /// and the first half of honouring it is that the boundary itself does not throw. That is asserted
    /// literally - the call is wrapped and the exception, if any, is failed on with the class named -
    /// rather than inferred from the fact that a response came back, because a response and an
    /// exception are different observations and only one of them is the claim.
    /// </para>
    /// <para>
    /// <b>The prohibited class is in this theory on purpose.</b> A prohibition is not a fourth
    /// degradation posture, but a caller holding a prohibited capability is still a caller that will
    /// make a request during an outage, and the estate must answer it with a typed response rather
    /// than an exception like any other.
    /// </para>
    /// </remarks>
    [Theory]
    [InlineData(AiCapabilities.CodeGenerate, AiDependencyClass.AiOptional)]
    [InlineData(AiCapabilities.ArchitectureReview, AiDependencyClass.AiEnhanced)]
    [InlineData(AiCapabilities.ChatComplete, AiDependencyClass.AiDependent)]
    [InlineData(AiCapabilities.CodeReview, AiDependencyClass.AiProhibited)]
    public async Task AnOutage_IsAnsweredForEveryDependencyClass_AndNothingThrows(
        string capability,
        AiDependencyClass declared)
    {
        var options = For(capability, declared);
        var path = GovernedPath.Compose(options);
        Outage(path);

        var gateway = GatewayFor(path);

        var response = await Record.ExceptionAsync(
            () => gateway.InvokeAsync(Request($"req-w7g-outage-{declared}") with
            {
                Capability = CapabilityId.Parse(capability),
            }));

        // The claim, stated as an exception rather than as a null response: nothing escaped.
        Assert.Null(response);

        // NON-VACUITY: the estate really is an estate of this class, so the answer above is about
        // that class and not about a fixture that declared something else. The two sources are
        // checked where each actually lives, because they are not the same source: the three
        // availability classes are the capability register's own, and a prohibited capability has no
        // bootstrap registration at that class - the prohibition is the dependency register's, and
        // that is what is asserted for it.
        if (declared is AiDependencyClass.AiProhibited)
        {
            Assert.True(
                new AiDependencyRegistry(options.Dependencies)
                    .IsCapabilityProhibited(CapabilityId.Parse(capability)),
                $"'{capability}' must be declared AI-prohibited, or the fixture is not about that class.");
        }
        else
        {
            Assert.Equal(declared, DeclaredClass(capability));
        }
    }

    /// <summary>
    /// The boundary's non-AI functions keep working while the AI path is unavailable.
    /// </summary>
    /// <remarks>
    /// <b>"Unrelated functions" is not an abstraction here, and this is what it means at this
    /// boundary.</b> A Product that cannot reach a model still has to discover what the Head would
    /// serve, and an operator still has to read the operations surface. Those are the two functions
    /// on this boundary that do not depend on a provider answering, and an outage that took them with
    /// it would turn a degraded feature into a degraded product - which is the failure the dependency
    /// classes exist to bound.
    /// </remarks>
    [Fact]
    public async Task AnOutage_LeavesTheBoundarysNonAiFunctionsWorking()
    {
        var path = GovernedPath.Compose(For(AiCapabilities.ChatComplete, AiDependencyClass.AiDependent));
        Outage(path);

        var gateway = GatewayFor(path);

        // An authenticated read of the capability register: no provider is consulted and none is
        // needed. It answers in full, not in part, and it answers while the Head is down.
        var capabilities = await gateway.ListCapabilitiesAsync();

        // NON-VACUITY: the register is populated, so "it answered" is the register rather than an
        // empty list that would also satisfy a bare non-null assertion.
        Assert.NotEmpty(capabilities);
        Assert.Contains(capabilities, entry => entry.Capability.Value == AiCapabilities.ChatComplete);

        // The operations surface, over an estate that has recorded nothing and cannot record
        // anything: a query is a legitimate empty answer rather than an error.
        var summary = path.Operations.Summarize(new AiOperationsQuery(), AiUsageGroupBy.Capability);

        Assert.Empty(summary.Buckets);

        // And the request that does depend on AI is still answered as a typed response, so the two
        // working functions above are not an accident of the request never being made.
        var dependent = await gateway.InvokeAsync(Request("req-w7g-outage-control"));

        Assert.Equal(AiExecutionStatus.Degraded, dependent.Status);
    }

    // ---------------------------------------------------------------------------------------------
    // B. AI_OPTIONAL and AI_ENHANCED.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task AnOptionalCapability_WithTheHeadUp_IsServed()
    {
        var options = For(AiCapabilities.CodeGenerate, AiDependencyClass.AiOptional);
        var path = GovernedPath.Compose(options);

        var response = await GatewayFor(path).InvokeAsync(Request("req-w7g-optional-up") with
        {
            Capability = CapabilityId.Parse(AiCapabilities.CodeGenerate),
        });

        Assert.Equal(AiExecutionStatus.Succeeded, response.Status);
        Assert.False(response.IsDegraded);
        Assert.Null(response.Failure);
        Assert.NotNull(response.Execution);
    }

    /// <summary>
    /// An optional capability during an outage takes the deterministic path and says so.
    /// </summary>
    /// <remarks>
    /// The three assertions that matter are that the status is <see cref="AiExecutionStatus.Degraded"/>
    /// rather than <see cref="AiExecutionStatus.Failed"/> - an optional capability is one the caller
    /// can do without, so the outage is not a failure - that no execution identity was issued, and
    /// that the reason is the estate's typed <see cref="AiFailureCategory.AiUnavailable"/> rather than
    /// an empty response the caller has to interpret.
    /// </remarks>
    [Fact]
    public async Task AnOptionalCapability_DuringAnOutage_IsLabelledDegraded()
    {
        var options = For(AiCapabilities.CodeGenerate, AiDependencyClass.AiOptional);
        var path = GovernedPath.Compose(options);
        Outage(path);

        var response = await GatewayFor(path).InvokeAsync(Request("req-w7g-optional-down") with
        {
            Capability = CapabilityId.Parse(AiCapabilities.CodeGenerate),
        });

        Assert.Equal(AiExecutionStatus.Degraded, response.Status);
        Assert.True(response.IsDegraded);

        // Nothing ran, so nothing is claimed to have run: no execution reference, no output, no cost.
        Assert.Null(response.Execution);
        Assert.Null(response.Output);
        Assert.Equal(0, path.Model.Count);
        Assert.Empty(path.Ledger.Entries());

        Assert.NotNull(response.Failure);
        Assert.Equal(AiFailureCategory.AiUnavailable, response.Failure!.Category);
    }

    /// <summary>
    /// An enhanced capability during the same outage receives exactly the optional one's answer.
    /// </summary>
    /// <remarks>
    /// <b>This is the finding, asserted as an equality rather than described.</b> The two classes make
    /// different claims in the register - one says the operation completes identically without AI, the
    /// other says it completes worse - and at the boundary the estate gives both callers the same
    /// status, the same failure category and the same absence of an execution. That is correct given
    /// what the estate can know: the difference the register describes is a difference in the caller's
    /// own product, which the AI Head cannot observe and therefore cannot report. The test exists so
    /// the equivalence is a recorded property of the estate rather than a reader's inference from two
    /// files, and so a future change that made the class select the behaviour would fail here and have
    /// to say why.
    /// </remarks>
    [Fact]
    public async Task AnEnhancedAndAnOptionalCapability_ReceiveTheSameAnswer_DuringAnOutage()
    {
        var optional = For(AiCapabilities.CodeGenerate, AiDependencyClass.AiOptional);
        var enhanced = For(AiCapabilities.ArchitectureReview, AiDependencyClass.AiEnhanced);

        var optionalPath = GovernedPath.Compose(optional);
        var enhancedPath = GovernedPath.Compose(enhanced);

        Outage(optionalPath);
        Outage(enhancedPath);

        var fromOptional = await GatewayFor(optionalPath).InvokeAsync(Request("req-w7g-pair-a") with
        {
            Capability = CapabilityId.Parse(AiCapabilities.CodeGenerate),
        });

        var fromEnhanced = await GatewayFor(enhancedPath).InvokeAsync(Request("req-w7g-pair-b") with
        {
            Capability = CapabilityId.Parse(AiCapabilities.ArchitectureReview),
        });

        // The classes are genuinely different declarations...
        Assert.NotEqual(DeclaredClass(AiCapabilities.CodeGenerate), DeclaredClass(AiCapabilities.ArchitectureReview));

        // ...and the answers are the same one.
        Assert.Equal(fromOptional.Status, fromEnhanced.Status);
        Assert.Equal(fromOptional.IsDegraded, fromEnhanced.IsDegraded);
        Assert.Equal(fromOptional.Failure!.Category, fromEnhanced.Failure!.Category);
        Assert.Equal(fromOptional.Execution, fromEnhanced.Execution);
    }

    /// <summary>
    /// The same enhanced capability, with the caller's own policy changed, fails instead.
    /// </summary>
    /// <remarks>
    /// The axis is the caller's policy, and this is the half that proves it. The test above shows the
    /// class does not choose; this one shows what does. An enhanced caller that cannot accept a worse
    /// answer has said so in its own request, and the estate's job is to report that rather than to
    /// decide it - which is the behaviour the directive's "do not turn genuine AI-dependent failures
    /// into SKIP" is the test-suite half of.
    /// </remarks>
    [Fact]
    public async Task TheSameEnhancedCapability_WithACallerThatAskedToFail_Fails()
    {
        var options = For(AiCapabilities.ArchitectureReview, AiDependencyClass.AiEnhanced);
        var path = GovernedPath.Compose(options);
        Outage(path);

        var gateway = GatewayFor(path);

        var response = await gateway.InvokeAsync(Request("req-w7g-enhanced-fail") with
        {
            Capability = CapabilityId.Parse(AiCapabilities.ArchitectureReview),
            Execution = new AiExecutionPolicy
            {
                Quality = AiQualityRequirement.Complete,
                OnDegradation = AiDegradationPreference.Fail,
            },
        });

        Assert.Equal(AiExecutionStatus.Failed, response.Status);

        // Not degraded: a caller that asked to fail has been refused, not handed a deterministic
        // answer. The label is withheld because it would be false, not because it is unavailable.
        Assert.False(response.IsDegraded);

        // The same typed category as the degraded reading, so a caller branches on one value.
        Assert.Equal(AiFailureCategory.AiUnavailable, response.Failure!.Category);
        Assert.Null(response.Execution);

        // NON-VACUITY: the identical estate under the default preference is Degraded, so the status
        // above is the policy being read rather than a constant.
        var defaulted = await gateway.InvokeAsync(Request("req-w7g-enhanced-default") with
        {
            Capability = CapabilityId.Parse(AiCapabilities.ArchitectureReview),
        });

        Assert.Equal(AiExecutionStatus.Degraded, defaulted.Status);
    }

    // ---------------------------------------------------------------------------------------------
    // C. AI_DEPENDENT — the class that says there is nothing to degrade to.
    // ---------------------------------------------------------------------------------------------

    /// <summary>
    /// A dependent capability whose caller asked to fail fails, and is not skipped.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The directive forbids turning a genuine AI-dependent failure into a SKIP to make a suite
    /// green, and this test is written so that doing so would break the build rather than pass it.</b>
    /// A skipped run reports neither Passed nor Failed, so a suite that skipped here would still be
    /// green while the only assertion about the dependent class had stopped being made. The gate is
    /// therefore explicit and mechanical: <c>skipped == 0</c> over the whole assembly, asserted in
    /// §7 of W7G_BUILD_TEST_EVIDENCE.md's command, and the two tests below are the ones it covers.
    /// </para>
    /// <para>
    /// The register's own predicate is asserted alongside the response, so the failure is attributable
    /// to a capability the estate has declared cannot survive an outage rather than to a fixture that
    /// happened to fail.
    /// </para>
    /// </remarks>
    [Fact]
    public async Task ADependentCapability_WhoseCallerAskedToFail_Fails_AndIsNotSkipped()
    {
        // The declaration, read independently of the request path: this feature cannot survive an
        // outage. An undeclared feature would also answer false here, so the class is asserted too.
        var register = new AiDependencyRegistry([Declaration("chat.reply", AiDependencyClass.AiDependent)]);

        Assert.False(register.MustSurviveAiOutage("chat.reply"));
        Assert.Equal(AiDependencyClass.AiDependent, DeclaredClass(AiCapabilities.ChatComplete));

        var path = GovernedPath.Compose(For(AiCapabilities.ChatComplete, AiDependencyClass.AiDependent));
        Outage(path);

        var response = await GatewayFor(path).InvokeAsync(Request("req-w7g-dependent-fail") with
        {
            Execution = new AiExecutionPolicy
            {
                Quality = AiQualityRequirement.Complete,

                // What an AI-dependent caller must say, and the only thing in the estate that makes the
                // class operational: there is no deterministic path, so the honest answer is a failure.
                OnDegradation = AiDegradationPreference.Fail,
            },
        });

        Assert.Equal(AiExecutionStatus.Failed, response.Status);
        Assert.False(response.IsDegraded);
        Assert.Equal(AiFailureCategory.AiUnavailable, response.Failure!.Category);

        // Nothing ran and nothing is claimed to have run - the containment the class exists to give.
        Assert.Null(response.Execution);
        Assert.Equal(0, path.Model.Count);
    }

    /// <summary>
    /// A dependent capability under the default preference is labelled degraded — which is the hazard.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>This test records a real and unresolved hazard, and it is written to make it visible rather
    /// than to bless it.</b> <see cref="AiExecutionPolicy.OnDegradation"/> defaults to
    /// <see cref="AiDegradationPreference.ReturnDeterministicResult"/>. For a capability whose own
    /// declaration says no deterministic path exists, that default asks the caller to take a path the
    /// register has already stated is not there - and the estate answers
    /// <see cref="AiExecutionStatus.Degraded"/>, which is the label for "your deterministic answer is
    /// on its way".
    /// </para>
    /// <para>
    /// It is not a defect with a one-line fix. Making the class force <c>Fail</c> would put the
    /// register in the serving path, which <see cref="AiDependencyRegistry"/>'s own remarks forbid
    /// ("nothing here is consulted when serving a request"); and defaulting the policy per class would
    /// silently override a caller's stated preference, which is the estate deciding something the
    /// caller already said. Either would be a contract change across every consumer estate and belongs
    /// to the Human Owner, not to this lane.
    /// </para>
    /// <para>
    /// What the test pins is the divergence itself, so that it cannot change unnoticed: the register
    /// says the feature does not survive, the boundary says the caller has been degraded, and both
    /// facts are asserted in the same test where they can be read together.
    /// </para>
    /// </remarks>
    [Fact]
    public async Task ADependentCapability_UnderTheDefaultPreference_IsLabelledDegraded()
    {
        var register = new AiDependencyRegistry([Declaration("chat.reply", AiDependencyClass.AiDependent)]);

        Assert.False(register.MustSurviveAiOutage("chat.reply"));

        var path = GovernedPath.Compose(For(AiCapabilities.ChatComplete, AiDependencyClass.AiDependent));
        Outage(path);

        // No policy stated: the shipped default, which is what a caller that has not thought about
        // degradation receives.
        var response = await GatewayFor(path).InvokeAsync(Request("req-w7g-dependent-default"));

        Assert.Equal(AiExecutionStatus.Degraded, response.Status);
        Assert.True(response.IsDegraded);
        Assert.Equal(AiFailureCategory.AiUnavailable, response.Failure!.Category);

        // The divergence, in one place: the label the caller acts on, next to the declaration that
        // says there is nothing behind it.
        Assert.False(register.MustSurviveAiOutage("chat.reply"));
        Assert.Equal(AiExecutionStatus.Degraded, response.Status);
    }

    // ---------------------------------------------------------------------------------------------
    // D. AI_PROHIBITED — a standing refusal, and what an outage does to it.
    // ---------------------------------------------------------------------------------------------

    /// <summary>
    /// With the Head up, a prohibited capability is blocked before any route is selected.
    /// </summary>
    /// <remarks>
    /// The control for the test below, and the reason it is repeated here rather than cited: the pair
    /// has to be composed over one estate for the difference between the two answers to be
    /// attributable to the outage. W7F's own version of this assertion is over a different fixture.
    /// </remarks>
    [Fact]
    public async Task AProhibitedCapability_WithTheHeadUp_IsBlocked()
    {
        var options = For(AiCapabilities.CodeReview, AiDependencyClass.AiProhibited);
        var path = GovernedPath.Compose(options);

        var response = await GatewayFor(path).InvokeAsync(Request("req-w7g-prohibited-up") with
        {
            Capability = CapabilityId.Parse(AiCapabilities.CodeReview),
        });

        Assert.Equal(AiExecutionStatus.Blocked, response.Status);
        Assert.Equal(AiFailureCategory.PolicyBlocked, response.Failure!.Category);
        Assert.False(response.PolicyDecision!.Allowed);
        Assert.False(response.IsDegraded);

        // A refusal is not an invocation: no provider was reached and nothing was recorded.
        Assert.Equal(0, path.Model.Count);
        Assert.Empty(path.Ledger.Entries());

        // A refusal IS a record, so the caller keeps a resolvable reference to it. This is the
        // contrast the outage tests below turn on: a refused execution happened and can be read back;
        // an unavailable Head means nothing happened and no identity is issued for it. An estate that
        // issued one here, or withheld one there, would be telling the caller the opposite of the
        // truth about whether anything ran.
        Assert.NotNull(response.Execution);
    }

    /// <summary>
    /// With the Head down, the outage answer comes first and the caller is told the policy allowed it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>A finding, not an expectation.</b> The gateway asks the availability question before it
    /// translates anything, so on an estate whose Head is unavailable a prohibited capability never
    /// reaches governance. The caller receives the outage answer - and, because the degraded path
    /// carries <see cref="AiPolicyDecision.AllowedByDefault"/>, a policy decision reading
    /// <c>Allowed = true</c> with no rules applied.
    /// </para>
    /// <para>
    /// <b>It is not a bypass and the assertions below say so structurally.</b> Nothing ran: no
    /// provider was reached, no ledger entry exists, no execution identity was issued, and no model
    /// output is on the response. A prohibition is not escaped by an outage; the AI simply is not
    /// there to participate either way.
    /// </para>
    /// <para>
    /// <b>What it does mean is that a caller and an operator cannot tell a standing prohibition from
    /// a temporary outage on this path.</b> The two are different instructions: a prohibited capability
    /// will never be served and its caller should change what it does, whereas an outage resolves. A
    /// reader of the operations graph sees a degradation, and a Product that branches on
    /// <c>PolicyDecision.Allowed</c> reads <c>true</c> about an execution its own declaration forbids.
    /// Recorded as W7G-R F-3 in W7G_DEGRADED_MODE.md rather than fixed here: moving governance ahead of
    /// the availability gate is an ordering change at the boundary that would make policy decide about
    /// executions that never run, and it belongs to the Human Owner.
    /// </para>
    /// </remarks>
    [Fact]
    public async Task AProhibitedCapability_DuringAnOutage_IsReportedAsAnOutage()
    {
        var options = For(AiCapabilities.CodeReview, AiDependencyClass.AiProhibited);
        var path = GovernedPath.Compose(options);
        Outage(path);

        var response = await GatewayFor(path).InvokeAsync(Request("req-w7g-prohibited-down") with
        {
            Capability = CapabilityId.Parse(AiCapabilities.CodeReview),
        });

        // The outage reading, and not the prohibition. Asserted as an inequality against the control's
        // status so the difference between the pair is the assertion rather than a literal.
        Assert.Equal(AiExecutionStatus.Degraded, response.Status);
        Assert.NotEqual(AiExecutionStatus.Blocked, response.Status);
        Assert.Equal(AiFailureCategory.AiUnavailable, response.Failure!.Category);
        Assert.NotEqual(AiFailureCategory.PolicyBlocked, response.Failure.Category);

        // The policy verdict that is the substance of the finding: no policy was consulted on this
        // path, and the value the caller reads says the execution was allowed.
        Assert.True(response.PolicyDecision!.Allowed);
        Assert.Empty(response.PolicyDecision.RulesApplied);
        Assert.Null(response.PolicyDecision.Reason);

        // NOT A BYPASS: nothing ran, nothing was recorded, nothing was issued, nothing was returned.
        Assert.Equal(0, path.Model.Count);
        Assert.Empty(path.Ledger.Entries());
        Assert.Null(response.Execution);
        Assert.Null(response.Output);
    }

    /// <summary>
    /// A prohibition declared in the register is not made servable by an outage either.
    /// </summary>
    /// <remarks>
    /// The prohibition here is a Product's own capability-shaped declaration rather than a class in the
    /// capability register, which is the other shape a prohibition takes. An outage does not lift it:
    /// the estate still does not serve the capability, and the caller still receives no AI output. The
    /// assertion is on the thing that would actually be a bypass - a served execution - rather than on
    /// the status code, because the finding above is precisely that the status code is not the
    /// prohibition's to report right now.
    /// </remarks>
    [Fact]
    public async Task ARegisterProhibitedCapability_IsStillNotServed_DuringAnOutage()
    {
        var prohibited = TwoRoutesProhibiting(AiCapabilities.CodeReview);
        var path = GovernedPath.Compose(prohibited);
        Outage(path);

        var response = await GatewayFor(path).InvokeAsync(Request("req-w7g-register-prohibited") with
        {
            Capability = CapabilityId.Parse(AiCapabilities.CodeReview),
        });

        Assert.Equal(0, path.Model.Count);
        Assert.Empty(path.Ledger.Entries());
        Assert.Null(response.Execution);
        Assert.Null(response.Output);

        // NON-VACUITY: the same estate with the Head up IS refused by the prohibition, so the
        // zero above is not a fixture that refuses everything for an unrelated reason.
        var healthy = GovernedPath.Compose(prohibited);
        var refused = await GatewayFor(healthy).InvokeAsync(Request("req-w7g-register-prohibited-up") with
        {
            Capability = CapabilityId.Parse(AiCapabilities.CodeReview),
        });

        Assert.Equal(AiExecutionStatus.Blocked, refused.Status);
        Assert.Equal(AiFailureCategory.PolicyBlocked, refused.Failure!.Category);
    }

    // ---------------------------------------------------------------------------------------------
    // E. The status vocabulary: which readings the boundary can and cannot reach.
    // ---------------------------------------------------------------------------------------------

    /// <summary>
    /// An observed outage and an unobserved Head are different readings, and an operator needs both.
    /// </summary>
    /// <remarks>
    /// A caller receives the same answer either way - it is not going to act differently on the
    /// difference - but an operator does, and the projection is where the difference survives. An
    /// estate whose probes have not run yet is not an estate that has gone down, and reporting the
    /// first as the second would turn every startup, and every probe window of the monitoring plane
    /// itself, into an apparent outage. The projection's own remarks call this "the state most often
    /// got wrong", and this is what pins the two apart.
    /// </remarks>
    [Fact]
    public void AnUnobservedHead_IsUnknown_AndAnObservedOutage_IsUnavailable()
    {
        var capabilities = AiCapabilityRegister.Bootstrap();

        var unobserved = GovernedPath.Compose(For(AiCapabilities.ChatComplete, AiDependencyClass.AiDependent));
        unobserved.Health.Publish(new AiHealthSnapshot
        {
            TakenAt = DateTimeOffset.UnixEpoch,
            Source = "w7g-degraded-mode-nothing-observed",
        });

        var observed = GovernedPath.Compose(For(AiCapabilities.ChatComplete, AiDependencyClass.AiDependent));
        Outage(observed);

        var unknown = new AiGatewayAvailabilityProjection(unobserved.Health, capabilities, TimeProvider.System).Read();
        var unavailable = new AiGatewayAvailabilityProjection(observed.Health, capabilities, TimeProvider.System).Read();

        Assert.Equal(AiAvailabilityState.Unknown, unknown.State);
        Assert.Equal(AiAvailabilityReason.HealthUnpublished, unknown.Reason);

        Assert.Equal(AiAvailabilityState.Unavailable, unavailable.State);
        Assert.Equal(AiAvailabilityReason.NoUsableRoute, unavailable.Reason);

        // Neither is servable, which is why a caller cannot tell them apart - and why the difference
        // above is the operator's and not a caller's.
        Assert.False(unknown.IsServable);
        Assert.False(unavailable.IsServable);
    }

    /// <summary>
    /// The write-approval gate closes the only route to a proposed action, so nothing reaches it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>This is an executed proof that a status is unreachable, which is a different and stronger
    /// claim than "no test covers it".</b> <see cref="AiExecutionStatus.PartiallySucceeded"/> is
    /// produced by exactly one branch - a run whose tool loop proposed an action without executing it
    /// (<c>GovernedTurnExecution</c>, the <c>ProposedActions.Count &gt; 0</c> test) - and the loop
    /// proposes only when the tool is not read-only AND the constraints require approval for writes.
    /// The gateway sets that flag unconditionally, and the tool's own declaration refuses a
    /// non-read-only tool before the model is reached, so the model is never handed a tool it could
    /// propose. The zero on the model seam below is that gate closing, measured.
    /// </para>
    /// <para>
    /// <b>The requester is widened and that is what makes the claim attributable.</b> Left at the
    /// fixture's default it does not permit side effects, so an earlier gate refuses the turn and the
    /// zero below would be that gate rather than the tool's declaration - a test passing for a reason
    /// it did not name. Every source of approval the caller controls is therefore turned off, as
    /// W7D's own version of this control does, so the tool's declaration is the only gate left.
    /// </para>
    /// <para>
    /// <b>The same branch is the only producer of the tool-loop reading of
    /// <see cref="AiExecutionStatus.Degraded"/></b> - a loop whose final result was unsuccessful -
    /// because a loop only reaches a final result at all if it executed something first, and the same
    /// gate stands in front of that. So two of the six statuses on a caller-facing enum are computed
    /// by the audit record and unreachable through the boundary, and the gateway's own status function
    /// cannot emit either of them in any case. Recorded as W7G-R F-4 in W7G_DEGRADED_MODE.md.
    /// </para>
    /// </remarks>
    [Theory]
    [InlineData("Write")]
    [InlineData("Destructive")]
    public async Task ANonReadOnlyTool_NeverReachesTheModel_SoNothingCanBeProposed(string sideEffect)
    {
        var options = TwoRoutes() with
        {
            Tools = [GovernedPath.Tool("tool.mutate", sideEffect: sideEffect)],
            OfferedToolIds = ["tool.mutate"],
            Replies = ["[tool:tool.mutate]{\"q\":\"x\"}", "Done."],
        };

        var path = GovernedPath.Compose(options);

        var response = await GatewayFor(path, GovernedPath.Descriptor("tool.mutate")).InvokeAsync(
            Request($"req-w7g-proposed-{sideEffect}") with
            {
                Tools = new ToolPermissionProfile { AllowedToolIds = ["tool.mutate"] },
                Requester = GovernedPath.Requester(
                    mayCauseSideEffects: true,
                    requiresHumanApprovalForSideEffects: false),
            });

        // The tool's declaration stops it, and stops it as a human decision rather than as a failure:
        // the tool is not forbidden, it is not to be written without a person. The category says the
        // same thing as the status, so a caller branching on either reaches the same branch.
        Assert.Equal(AiExecutionStatus.PendingHumanDecision, response.Status);
        Assert.Equal(AiFailureCategory.HumanDecisionRequired, response.Failure!.Category);

        // The measurement the claim rests on: the model was never handed the tool, so it had nothing
        // to propose and no proposal could be recorded.
        Assert.Equal(0, path.Model.Count);
        Assert.Empty(path.Ledger.Entries());
    }

    // ---------------------------------------------------------------------------------------------
    // Fixtures.
    // ---------------------------------------------------------------------------------------------

    /// <summary>
    /// A one-route estate for one capability, declared at the class the register actually holds.
    /// </summary>
    /// <remarks>
    /// The capability's class is NOT a parameter of the register here: it is read from
    /// <see cref="AiCapabilityRegister.Bootstrap"/> by <see cref="DeclaredClass"/> and used to build
    /// the prohibition declaration when the class is <see cref="AiDependencyClass.AiProhibited"/>. A
    /// fixture that let a test state the class would let a test declare a class the estate does not
    /// hold, and every assertion below would then be about the fixture.
    /// </remarks>
    private static GovernedPathOptions For(string capability, AiDependencyClass declared) => new()
    {
        Capability = capability,
        Providers = [GovernedPath.ProviderEntry(PrimaryProvider, capabilities: [capability], priority: 10)],
        Models = [GovernedPath.ModelEntry(PrimaryModel, PrimaryProvider, capabilities: [capability])],

        // A prohibited capability reaches governance only if a declaration names it. The declaration
        // is derived from the class the register holds rather than restated, so the two cannot drift.
        Dependencies = declared is AiDependencyClass.AiProhibited
            ? [GovernedPath.Prohibited(capability)]
            : [],
    };

    /// <summary>Two routes over an estate whose capability is prohibited by a register declaration.</summary>
    private static GovernedPathOptions TwoRoutesProhibiting(string capability)
        => TwoRoutes() with
        {
            Capability = capability,
            Dependencies = [GovernedPath.Prohibited(capability)],
        };

    /// <summary>The class the estate's own capability register declares for a capability.</summary>
    private static AiDependencyClass DeclaredClass(string capability)
    {
        var resolved = AiCapabilityRegister.Bootstrap()
            .TryResolve(CapabilityId.Parse(capability), out var registration);

        Assert.True(resolved, $"'{capability}' must be registered, or the fixture is not about a class.");
        Assert.NotNull(registration);

        return registration!.DependencyClass;
    }

    /// <summary>A dependency declaration that passes validation for the class it states.</summary>
    /// <remarks>
    /// The two class-specific fields are supplied on the classes that require them and left empty on
    /// the others, because the registry refuses both directions: an <c>AiDependent</c> declaration that
    /// claims a deterministic fallback and an <c>AiOptional</c> one that names an accepted-risk owner
    /// are both rejected, and either would fail as a fixture error rather than as the property under
    /// test.
    /// </remarks>
    private static AiDependencyDeclaration Declaration(string featureId, AiDependencyClass declared) => new()
    {
        FeatureId = featureId,
        Owner = "AI-03 AI Governance",
        DependencyClass = declared,
        Rationale = "W7G-R degraded-mode fixture.",
        DeterministicFallback = declared is AiDependencyClass.AiDependent ? null : "The deterministic path.",
        AcceptedRiskOwner = declared is AiDependencyClass.AiDependent ? "Human Owner" : null,
    };

    /// <summary>Publishes a snapshot in which no declared provider can serve.</summary>
    /// <remarks>
    /// A provider observed <see cref="AiModelHealthState.Unavailable"/> rather than an empty snapshot,
    /// and the difference is deliberate: an empty snapshot reads as
    /// <see cref="AiAvailabilityState.Unknown"/> - nobody has looked - which is also not servable but
    /// is a different fact, and every test in this file is about an outage that was observed. The
    /// unknown reading is proved in its own test in §A rather than blended into these.
    /// </remarks>
    private static void Outage(GovernedPath path)
    {
        path.Health.Publish(new AiHealthSnapshot
        {
            TakenAt = DateTimeOffset.UnixEpoch,
            Source = "w7g-degraded-mode-observed-outage",
            Providers = new Dictionary<string, AiModelHealthState>(StringComparer.Ordinal)
            {
                [PrimaryProvider] = AiModelHealthState.Unavailable,
            },
        });
    }

    /// <summary>The gateway over the composed path, exactly as W7F composes it.</summary>
    /// <remarks>
    /// The execution path, the operations read model and the health store are the estate's own
    /// objects, so an assertion here is about the estate rather than about a stand-in for it. Only the
    /// tool catalogue is replaced, because it is a Platform port this repository does not implement.
    /// It lists nothing unless a test names descriptors, which is the honest default: a catalogue with
    /// no entries is what an estate that has registered no tools looks like, and a test about tools
    /// states them.
    /// </remarks>
    private static AiCapabilityGateway GatewayFor(GovernedPath path, params ToolDescriptor[] tools)
    {
        var capabilities = AiCapabilityRegister.Bootstrap();

        return new AiCapabilityGateway(
            path.Execution,
            new AiGatewayAvailabilityProjection(path.Health, capabilities, TimeProvider.System),
            capabilities,
            path.Operations,
            new FixedToolCatalog(tools),
            new CountingAiExecutionIdSource(),
            TimeProvider.System);
    }

    /// <summary>The tools the Platform catalogue lists, as a fixed set.</summary>
    private sealed class FixedToolCatalog : IToolCatalog
    {
        private readonly IReadOnlyList<ToolDescriptor> _tools;

        public FixedToolCatalog(IReadOnlyList<ToolDescriptor> tools) => _tools = tools;

        public Task<IReadOnlyList<ToolDescriptor>> ListAsync(CancellationToken ct = default)
            => Task.FromResult(_tools);
    }
}
