using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Microsoft.Extensions.Configuration;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7E TASKS 3, 4 and 5 as repository-level facts about the COMMITTED configuration.
//
// WHY THIS FILE EXISTS. The operational plane's whole claim is that its limits belong to an operator:
// no ceiling, no success-rate floor and no failure ceiling is a constant in the routing code, and the
// posture an estate actually runs is therefore a fact about appsettings.json rather than about an
// assembly. That is a strong claim and it decays in a specific way — someone reaches for a convenient
// literal because the configuration is awkward, and the file keeps saying what it said while the code
// stops obeying it.
//
// So the checks below are made from outside the code that implements them. Two of them are SHAPE
// checks on the parsed configuration, and two are ABSENCE checks over the production source tree:
// a threshold that cannot be found in the code cannot be a threshold the file does not own.
//
// The values themselves are not asserted against literals where the contract already states them. The
// assertion is that the file and the contract agree, so a change to one that is not made to the other
// fails here rather than at the first refusal in an environment.
public sealed class W7eOperationsConfigurationTests
{
    /// <summary>A threshold assigned a literal, rather than read from configuration.</summary>
    /// <remarks>
    /// <para>
    /// The property is named, then its accessors if it has any, then an <c>=</c> and a literal, so an
    /// initializer (<c>MinimumSuccessRate { get; init; } = 0.5</c>) matches and a configuration read
    /// (<c>MinimumSuccessRate = configured.MinimumSuccessRate ?? defaults.MinimumSuccessRate</c>) does
    /// not. The right-hand side must <em>begin</em> with the literal, which is what keeps the second
    /// case out: a configuration read whose own fallback names a duration — <c>Cooldown = configured
    /// .CooldownSeconds is { } s ? TimeSpan.FromSeconds(s) : defaults.Cooldown</c> — has a
    /// <c>TimeSpan.From</c> on the line, and a pattern that searched the whole line for one would
    /// report the very construct the file requires.
    /// </para>
    /// <para>
    /// <b>The recovery model's parameters are in this list, and that is the point of listing them.</b>
    /// W7G-R added a second policy with its own numbers; a threshold that is configurable in principle
    /// and a literal in fact is the decay this whole file exists to catch, and it would have caught
    /// nothing if the new members had simply not been named here.
    /// </para>
    /// </remarks>
    private static readonly System.Text.RegularExpressions.Regex ThresholdAssignment = new(
        @"(MinimumSampleSize|MinimumSuccessRate|ConsecutiveFailureCeiling|EvidenceLifetime"
            + @"|Cooldown|ProbeAllowance|ProbeSuccessesRequired)\b\s*(?:\{[^}]*\}\s*)?=\s*"
            + @"(?:[0-9]|TimeSpan\.From)",
        System.Text.RegularExpressions.RegexOptions.Compiled
            | System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    // ---------------------------------------------------------------------------------------------
    // The committed section, as the composition root binds it.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void TheCommittedBudgetTable_IsEmptyAndRefusesUncoveredPricedExecution()
    {
        // TASK 3's "do not silently treat missing policy as unlimited unless that is an explicit rule".
        // The shipped file covers nothing and says what that means. Both halves are required: an empty
        // table with Allow written next to it would be a permissive estate that looked configured, and
        // a Refuse posture with a populated table would be a ceiling nobody chose.
        var configuration = ReadCommittedOperations();

        Assert.Empty(configuration.Budget.Rules);

        var policy = configuration.BudgetPolicy();

        Assert.True(policy.Available, "The operational budget plane must be evaluated on the shipped estate.");
        Assert.Equal(AiBudgetUncoveredBehaviour.Refuse, policy.OnUncoveredPricedExecution);

        // ...and the posture is a refusal in practice, not only in a field. An uncovered priced
        // execution is refused by the same evaluator the composition root builds over this policy.
        var evaluator = new ConfiguredAiBudgetEvaluator(policy);

        var refused = evaluator.Evaluate(Priced(1.00m));

        Assert.Equal(AiGovernanceVerdict.Block, refused.Verdict);
        Assert.Null(refused.RuleId);

        // W10.7A OWNER RULING: the shipped posture refuses an UNPRICED execution too, and this
        // assertion was reversed to match. It previously read Allow, which was the pinned contract
        // default — a posture no configuration key could change. Both postures now come from the same
        // policy and both are refused on the committed estate, so an unpriced execution is blocked on
        // a decision the estate actually made.
        Assert.Equal(AiBudgetUncoveredBehaviour.Refuse, policy.OnUnpricedExecution);

        var unpriced = evaluator.Evaluate(Priced(null));

        Assert.Equal(AiGovernanceVerdict.Block, unpriced.Verdict);

        // CONTROL, from the same evaluator: switching the ONE member that decides this permits the very
        // same call, so the refusal above is attributable to the posture and not to a gate that refuses
        // everything it is shown.
        var permitted = new ConfiguredAiBudgetEvaluator(policy with
        {
            OnUnpricedExecution = AiBudgetUncoveredBehaviour.Allow,
        }).Evaluate(Priced(null));

        Assert.Equal(AiGovernanceVerdict.Allow, permitted.Verdict);
    }

    [Fact]
    public void TheCommittedReliabilityAndHealthSections_StateTheContractsOwnValues()
    {
        // TASK 5's "thresholds belong in configuration/policy". The file restates the contract's
        // shipped values so that the gate an operator is running is readable where they run it. The
        // assertion is that the two agree: a contract default that moved without the file moving, or a
        // file value that silently diverged, fails here.
        var configuration = ReadCommittedOperations();
        var defaults = AiReliabilityPolicy.Default;

        var policy = configuration.ReliabilityPolicy();

        Assert.Equal(defaults.Enabled, policy.Enabled);
        Assert.Equal(defaults.MinimumSampleSize, policy.MinimumSampleSize);
        Assert.Equal(defaults.MinimumSuccessRate, policy.MinimumSuccessRate);
        Assert.Equal(defaults.ConsecutiveFailureCeiling, policy.ConsecutiveFailureCeiling);
        Assert.Equal(defaults.RequireEvidence, policy.RequireEvidence);
        Assert.Equal(defaults.EvidenceLifetime, policy.EvidenceLifetime);

        // TASK 4's composition, as a fact about the file. The sweep ships DISABLED: the estate registers
        // no probe that can conclude anything without the credential under human rotation, so an
        // enabled interval would publish the declared snapshot on a schedule and read as a live probe.
        // Disabled is the honest state, and ProbeInterval is how the composition root reads it.
        Assert.False(configuration.Health.Enabled);
        Assert.Null(configuration.ProbeInterval);
    }

    [Fact]
    public void TheCommittedRecoverySection_StatesTheContractsOwnValues_AndRefusesEveryBadOne()
    {
        // W7G-R TASK 2 and TASK 3(10), as facts about the committed file. The recovery model is what
        // releases a route the reliability gate has refused, so its parameters decide how long an
        // estate stays down after its provider comes back — which is exactly the kind of number that
        // must be an operator's decision rather than a constant somebody liked.
        var configuration = ReadCommittedOperations();
        var defaults = AiCircuitPolicy.Default;

        var policy = configuration.CircuitPolicy();

        Assert.Equal(defaults.Enabled, policy.Enabled);
        Assert.Equal(defaults.Cooldown, policy.Cooldown);
        Assert.Equal(defaults.ProbeAllowance, policy.ProbeAllowance);
        Assert.Equal(defaults.ProbeSuccessesRequired, policy.ProbeSuccessesRequired);

        // The failure half of the claim. A section that accepted these would be a section whose values
        // are decoration: each of them is a recovery model that cannot recover, wearing the vocabulary
        // of one. They are asserted to be REFUSED rather than to be corrected, because silently
        // repairing an operator's number is how an estate runs a policy nobody wrote.
        Assert.Throws<ArgumentException>(() => Configured(new AiCircuitConfigurationEntry
        {
            CooldownSeconds = 0,
        }).CircuitPolicy());

        Assert.Throws<ArgumentException>(() => Configured(new AiCircuitConfigurationEntry
        {
            ProbeAllowance = 0,
        }).CircuitPolicy());

        Assert.Throws<ArgumentException>(() => Configured(new AiCircuitConfigurationEntry
        {
            ProbeAllowance = 1,
            ProbeSuccessesRequired = 2,
        }).CircuitPolicy());

        // CONTROL, and the reason the three above are evidence rather than a composition root that
        // refuses everything: the same builder, given a policy that merely differs from the shipped
        // one, accepts it. Without this, a CircuitPolicy() that threw unconditionally would pass.
        var changed = Configured(new AiCircuitConfigurationEntry
        {
            CooldownSeconds = 300,
            ProbeAllowance = 3,
            ProbeSuccessesRequired = 2,
        }).CircuitPolicy();

        Assert.Equal(TimeSpan.FromMinutes(5), changed.Cooldown);
        Assert.Equal(3, changed.ProbeAllowance);
        Assert.Equal(2, changed.ProbeSuccessesRequired);
    }

    [Fact]
    public void TheCommittedRecoverySection_IsAbsentTolerant_SoAnExistingEstateIsNotForcedToChange()
    {
        // W7G-R TASK 3(10): a consumer's configuration does not have to change. An estate that has never
        // heard of the recovery model composes the shipped one rather than failing to start — which is
        // the whole difference between adding a policy and imposing one. The empty object here is what
        // an existing appsettings.json amounts to after binding, not a hypothetical.
        var policy = Configured(new AiCircuitConfigurationEntry()).CircuitPolicy();
        var defaults = AiCircuitPolicy.Default;

        Assert.True(policy.Enabled);
        Assert.Equal(defaults.Cooldown, policy.Cooldown);
        Assert.Equal(defaults.ProbeAllowance, policy.ProbeAllowance);
        Assert.Equal(defaults.ProbeSuccessesRequired, policy.ProbeSuccessesRequired);
    }

    // ---------------------------------------------------------------------------------------------
    // The thresholds are not in the code.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void NoProductionSource_HoldsAReliabilityThresholdOrAProviderPrice()
    {
        // TASK 5 and TASK 2 together, checked as an absence over the whole production tree rather than
        // as a property of a value. A threshold that exists as a literal is one an operator cannot
        // change, and a price in the code is a provider's price in the place the directive forbids it —
        // and in both cases the configuration file would go on claiming an authority it does not have.
        //
        // The corpus is every production source, not only the routing folder, because the interesting
        // failure is a threshold placed somewhere the reviewer was not looking. Comments are stripped
        // first: this estate documents its shipped values in prose, and a doc comment naming one is not
        // the code owning one.
        var codes = ProductionSources()
            .Select(file => (Path: file, Code: WithoutComments(File.ReadAllText(file))))
            .ToArray();

        Assert.NotEmpty(codes);
        Assert.All(codes, entry => Assert.NotEmpty(entry.Code));

        // Every production file whose code assigns a threshold from a literal. Assigning from
        // configuration — `configured.MinimumSuccessRate ?? defaults.MinimumSuccessRate` — is not a
        // match and is the supported way; a number written next to the property name is.
        var thresholdOwners = codes
            .Where(entry => ThresholdAssignment.IsMatch(entry.Code))
            .Select(entry => Path.GetRelativePath(RepositoryRoot, entry.Path))
            .ToArray();

        // The two contracts that define the values, and nothing else. Both are listed rather than the
        // check being widened to "some contract": the reliability plane's thresholds and the recovery
        // model's parameters are separate policies with separate homes, and a single file named here
        // would stop noticing if either one's literals moved into code that reads them.
        //
        // This assertion is its own control: a scanner that matched nothing would return an empty array
        // and fail here, so the absence is a fact about the tree rather than about the reader.
        Assert.Equal(
            [
                Path.Combine("src", "Nexus.Intelligence.Contracts", "Operations", "AiCircuit.cs"),
                Path.Combine("src", "Nexus.Intelligence.Contracts", "Operations", "AiReliabilityHistory.cs"),
            ],
            thresholdOwners);

        // ...and a provider's price is not in the code either. The figures are read from the committed
        // catalogue rather than written into this test, so re-pricing a model does not silently retire
        // the check.
        var prices = CommittedModelPrices();
        var committed = File.ReadAllText(CommittedSettingsPath);

        Assert.NotEmpty(prices);

        // CONTROL for the price half: the same strings are found in the file the estate actually
        // declares them in. Without this, a formatter that produced "0" for every price would make the
        // absence below true and meaningless.
        Assert.All(prices, price => Assert.Contains(price, committed, StringComparison.Ordinal));

        var priced = codes
            .SelectMany(entry => prices
                .Where(price => CarriesPrice(entry.Code, price))
                .Select(price => $"{Path.GetRelativePath(RepositoryRoot, entry.Path)} carries the price "
                    + $"literal {price}, which belongs to the registry's cost metadata."))
            .ToArray();

        Assert.Empty(priced);
    }

    [Fact]
    public void TheCompositionRoot_ReadsEveryOperationalSettingFromConfiguration()
    {
        // The wiring half. Each of these is a typed read of the section rather than a value chosen in
        // the extension method, which is what makes the file authoritative. Checked by reading the
        // composition root's own source, because the claim is about how it is written.
        var source = WithoutComments(
            File.ReadAllText(Path.Combine(
                ApiProjectDirectory,
                "DependencyInjection",
                "IntelligenceServiceCollectionExtensions.cs")));

        Assert.Contains("AiOperationsConfiguration.SectionName", source, StringComparison.Ordinal);
        Assert.Contains("operationsConfiguration.BudgetPolicy()", source, StringComparison.Ordinal);
        Assert.Contains("operationsConfiguration.ReliabilityPolicy()", source, StringComparison.Ordinal);

        // W7G-R's policy is read the same way. Without this line the recovery model could have been
        // composed from its contract defaults in the extension method, and every assertion in the file
        // above would still pass while the committed section did nothing.
        Assert.Contains("operationsConfiguration.CircuitPolicy()", source, StringComparison.Ordinal);

        // The candidate thresholds that would make the file advisory rather than authoritative: a
        // budget, reliability or recovery policy constructed inline would be a policy no operator can
        // change.
        Assert.DoesNotContain("new AiReliabilityPolicy", source, StringComparison.Ordinal);
        Assert.DoesNotContain("new AiOperationsBudgetPolicy", source, StringComparison.Ordinal);
        Assert.DoesNotContain("new AiCircuitPolicy", source, StringComparison.Ordinal);

        // ...and the health source registered for routing is the snapshot, not a prober. Routing must
        // read a published state and must not probe inline (TASK 4).
        Assert.Contains("SnapshotAiHealthSource", source, StringComparison.Ordinal);
        Assert.Contains("IAiHealthSnapshotStore", source, StringComparison.Ordinal);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------------------------------

    private static string RepositoryRoot { get; } = FindRepositoryRoot();

    private static string ApiProjectDirectory => Path.Combine(RepositoryRoot, "src", "Nexus.Intelligence.Api");

    /// <summary>One proposed execution against the committed budget policy, priced or not.</summary>
    /// <remarks>
    /// The route named is one the committed registry declares, so the context is the shape the gate
    /// actually receives rather than one invented to make the assertion convenient.
    /// </remarks>
    private static AiBudgetContext Priced(decimal? projected) => new()
    {
        Capability = CapabilityId.Parse(AiCapabilities.ChatComplete),
        ProviderId = "openai",
        ModelId = "openai:gpt-4.1",
        ProjectedCost = projected,
        Currency = projected is null ? null : "USD",
        Now = DateTimeOffset.UnixEpoch,
    };

    /// <summary>The committed operational configuration, as the composition root would bind it.</summary>
    private static AiOperationsConfiguration ReadCommittedOperations()
        => new ConfigurationBuilder()
            .AddJsonFile(CommittedSettingsPath, optional: false)
            .Build()
            .GetSection(AiOperationsConfiguration.SectionName)
            .Get<AiOperationsConfiguration>()
            ?? new AiOperationsConfiguration();

    /// <summary>The committed settings file, by absolute path.</summary>
    private static string CommittedSettingsPath => Path.Combine(ApiProjectDirectory, "appsettings.json");

    /// <summary>
    /// An operations configuration carrying one recovery section, for the parsing and validation checks.
    /// </summary>
    /// <remarks>
    /// Built in memory rather than written to a file, because what is under test is
    /// <see cref="AiOperationsConfiguration.CircuitPolicy"/> — the binder has its own coverage in the
    /// committed-section checks, and a temporary file would test both at once and attribute a failure
    /// to whichever ran first.
    /// </remarks>
    private static AiOperationsConfiguration Configured(AiCircuitConfigurationEntry recovery)
        => new() { Recovery = recovery };

    /// <summary>
    /// Every price the committed provider catalogue declares, as invariant decimal text.
    /// </summary>
    /// <remarks>
    /// Read from the file rather than written here, so this check follows a re-priced catalogue instead
    /// of going quietly stale against values nobody uses any more.
    /// </remarks>
    private static IReadOnlyList<string> CommittedModelPrices()
    {
        var models = new ConfigurationBuilder()
            .AddJsonFile(CommittedSettingsPath, optional: false)
            .Build()
            .GetSection("Platform:Providers:OpenAI:Catalog:Models")
            .GetChildren();

        var prices = new List<string>();

        foreach (var model in models)
        {
            foreach (var field in (string[])["CostPer1kIn", "CostPer1kOut"])
            {
                if (model[field] is { Length: > 0 } declared
                    && decimal.TryParse(
                        declared,
                        System.Globalization.NumberStyles.Number,
                        System.Globalization.CultureInfo.InvariantCulture,
                        out var price))
                {
                    prices.Add(price.ToString(System.Globalization.CultureInfo.InvariantCulture));
                }
            }
        }

        return [.. prices.Distinct(StringComparer.Ordinal).OrderBy(price => price, StringComparer.Ordinal)];
    }

    /// <summary>
    /// Whether source text carries a price as a literal of its own, rather than as the leading part of
    /// a longer number.
    /// </summary>
    /// <remarks>
    /// A decimal literal in C# carries an <c>m</c> and the JSON does not, so both forms count. The
    /// digit check is what keeps a price of <c>0.002</c> from being reported against source that
    /// declares <c>0.0025</c>: that would be a true finding naming the wrong value, which is worse than
    /// no finding because the message would send its reader to the wrong line.
    /// </remarks>
    private static bool CarriesPrice(string code, string price)
    {
        var index = code.IndexOf(price, StringComparison.Ordinal);

        while (index >= 0)
        {
            var after = index + price.Length;

            if (after >= code.Length || !char.IsAsciiDigit(code[after]))
            {
                return true;
            }

            index = code.IndexOf(price, after, StringComparison.Ordinal);
        }

        return false;
    }

    /// <summary>Every C# source in the production tree, excluding build output.</summary>
    private static IReadOnlyList<string> ProductionSources()
    {
        var root = Path.Combine(RepositoryRoot, "src");

        Assert.True(Directory.Exists(root), $"'{root}' does not exist, so nothing was checked.");

        return
        [
            .. Directory
                .GetFiles(root, "*.cs", SearchOption.AllDirectories)
                .Where(file => !file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal)
                    && !file.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
                .OrderBy(file => file, StringComparer.Ordinal),
        ];
    }

    /// <summary>
    /// Source text with comments removed: line comments, XML documentation, and block comments.
    /// </summary>
    /// <remarks>
    /// A scanner rather than a regular expression, because a regular expression that removed block
    /// comments would also remove the inside of a string literal that contained one, and this estate's
    /// sources contain prose in string literals. The trade this makes is the opposite one: string
    /// literals are kept, so a price hidden in a string is still found.
    /// </remarks>
    private static string WithoutComments(string source)
    {
        var stripped = new System.Text.StringBuilder(source.Length);
        var index = 0;

        while (index < source.Length)
        {
            if (index + 1 < source.Length && source[index] == '/' && source[index + 1] == '/')
            {
                while (index < source.Length && source[index] is not '\n')
                {
                    index++;
                }

                continue;
            }

            if (index + 1 < source.Length && source[index] == '/' && source[index + 1] == '*')
            {
                index += 2;

                while (index + 1 < source.Length && !(source[index] == '*' && source[index + 1] == '/'))
                {
                    index++;
                }

                index = Math.Min(index + 2, source.Length);
                continue;
            }

            stripped.Append(source[index]);
            index++;
        }

        return stripped.ToString();
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);

        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "Nexus.Intelligence.slnx")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        throw new InvalidOperationException(
            $"Could not locate Nexus.Intelligence.slnx above '{AppContext.BaseDirectory}'. The W7E "
            + "operational configuration checks cannot run without the repository root.");
    }
}
