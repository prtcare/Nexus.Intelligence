using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Roles;
using Nexus.Platform.Contracts.Models;
using Nexus.Intelligence.Tests.Registry;
using Xunit;

namespace Nexus.Intelligence.Tests.Registry;

/// <summary>
/// W10.7A — <b>the model-authority invariants.</b>
///
/// <para>
/// <b>The distinction under test, stated once.</b> There are two model surfaces and they have different
/// authoritative roles:
/// </para>
/// <list type="bullet">
/// <item><description><b>The Provider Model Catalogue</b> (<c>IModelCatalog</c>) lists models the
/// provider IMPLEMENTATION supports. Presence means <c>PROVIDER_SUPPORTED</c>.</description></item>
/// <item><description><b>The governed AI Model Registry</b> (<c>IAiModelRegistry</c>) lists models Nexus
/// may ROUTE to. Presence means <c>NEXUS_ROUTABLE</c>.</description></item>
/// </list>
///
/// <para>
/// <c>PROVIDER_SUPPORTED</c> does not imply <c>NEXUS_ROUTABLE</c>. Before the GATE 2 remediation,
/// <c>AiRoleResolver</c> read only the catalogue — so a role could resolve to a model the router must
/// then refuse. <b>`openai:gpt-4o` is the live instance of that class</b>: it is in the provider
/// catalogue and is deliberately NOT added to the governed registry.
/// </para>
///
/// <para>
/// <b>Every test is paired.</b> Each invariant is asserted against a control that would fail if the
/// guard were removed, because a test that only asserts "unsupported is refused" passes just as well
/// against a resolver that refuses everything.
/// </para>
/// </summary>
public sealed class ModelAuthorityInvariantTests
{
    private const string Routable = "openai:gpt-4.1";
    private const string ProviderOnly = "openai:gpt-4o";

    private static readonly DateTimeOffset AssignedAt = new(2026, 8, 30, 0, 0, 0, TimeSpan.Zero);

    /// <summary>The provider catalogue: it supports BOTH models. This is the A-only case's premise.</summary>
    private static readonly ModelDescriptor RoutableModel = new(
        Routable, "openai",
        ModelCapabilities.Chat | ModelCapabilities.Reasoning | ModelCapabilities.ToolUse |
        ModelCapabilities.Streaming | ModelCapabilities.StructuredOutput | ModelCapabilities.LongContext,
        1_047_576, 0.002m, 0.008m, LatencyClass.Medium);

    private static readonly ModelDescriptor ProviderOnlyModel = new(
        ProviderOnly, "openai",
        ModelCapabilities.Chat | ModelCapabilities.Reasoning | ModelCapabilities.ToolUse |
        ModelCapabilities.Streaming | ModelCapabilities.StructuredOutput | ModelCapabilities.LongContext,
        128_000, 0.0025m, 0.01m, LatencyClass.Medium);

    private static readonly AiRole Role = new(AiRole.DefaultRoleName, "Model-authority test role.");

    private static AiRoleAssignment Assign(string modelId) => new(
        AiRole.DefaultRoleName, modelId,
        ModelCapabilities.Chat | ModelCapabilities.Reasoning | ModelCapabilities.ToolUse |
        ModelCapabilities.Streaming | ModelCapabilities.StructuredOutput | ModelCapabilities.LongContext,
        AssignedAt);

    /// <summary>Catalogue says the provider supports both models. The registry is the variable.</summary>
    private static AiRoleResolver Resolver(IAiModelRegistry registry, string assignedModelId) =>
        new(
            new InMemoryAiRoleStore(seedRoles: [Role], seedAssignments: [Assign(assignedModelId)]),
            new Catalogue(RoutableModel, ProviderOnlyModel),
            registry);

    // ---------------------------------------------------------------- 1. A + B may route

    [Fact]
    public async Task Invariant1_A_model_in_both_surfaces_may_resolve()
    {
        var resolved = await Resolver(new GovernedModelRegistryStub(Routable, ProviderOnly), Routable)
            .ResolveAsync(AiRole.DefaultRoleName);

        Assert.NotNull(resolved.Model);
        Assert.Equal(Routable, resolved.Model!.ModelId);
    }

    // ---------------------------------------------------------------- 2 + 4. A only is not routable

    [Fact]
    public async Task Invariant2_A_model_in_the_provider_catalogue_only_does_not_resolve()
    {
        var resolved = await Resolver(new GovernedModelRegistryStub(Routable), ProviderOnly)
            .ResolveAsync(AiRole.DefaultRoleName);

        Assert.Null(resolved.Model);

        // The refusal NAMES the condition, so the operator is told which authority refused and why.
        Assert.Contains("PROVIDER_SUPPORTED_NOT_REGISTERED_FOR_ROUTING", resolved.Decision.What,
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task Invariant4_AiRoleResolver_cannot_return_a_provider_only_model()
    {
        // The live instance of the class: `openai:gpt-4o` is provider-supported and deliberately NOT
        // registered for routing. A resolver that returned it would hand the router a model it must
        // refuse — moving the failure away from the decision that caused it.
        var resolved = await Resolver(new GovernedModelRegistryStub(Routable), ProviderOnly)
            .ResolveAsync(AiRole.DefaultRoleName);

        Assert.NotEqual(ProviderOnly, resolved.Model?.ModelId);

        // CONTROL: the same resolver and the same catalogue DO resolve the registered model, so the
        // refusal above is the registry's membership test and not a resolver that refuses everything.
        var control = await Resolver(new GovernedModelRegistryStub(Routable), Routable)
            .ResolveAsync(AiRole.DefaultRoleName);

        Assert.Equal(Routable, control.Model?.ModelId);
    }

    // ---------------------------------------------------------------- 3. B only, provider unsupported

    [Fact]
    public async Task Invariant3_A_model_registered_but_absent_from_the_provider_catalogue_does_not_resolve()
    {
        // Registered for routing, but the provider catalogue does not list it — so no provider
        // implementation can serve it. Both surfaces must admit the model, which is why the resolver
        // consults the catalogue FIRST and the registry SECOND.
        var resolved = await Resolver(new GovernedModelRegistryStub(Routable, "openai:not-implemented"),
                "openai:not-implemented")
            .ResolveAsync(AiRole.DefaultRoleName);

        Assert.Null(resolved.Model);
        Assert.Contains("not in the Provider Model Catalogue", resolved.Decision.Why, StringComparison.Ordinal);
    }

    // ---------------------------------------------------------------- 5. provider support is not authorization

    [Fact]
    public async Task Invariant5_Provider_support_does_not_by_itself_authorize_routing()
    {
        // The catalogue is IDENTICAL in both arms — the provider supports gpt-4o either way. Only the
        // registry differs. That isolates the authority: adding support to A changed nothing.
        var catalogue = new Catalogue(RoutableModel, ProviderOnlyModel);

        var notRegistered = new AiRoleResolver(
            new InMemoryAiRoleStore(seedRoles: [Role], seedAssignments: [Assign(ProviderOnly)]),
            catalogue,
            new GovernedModelRegistryStub(Routable));

        var registered = new AiRoleResolver(
            new InMemoryAiRoleStore(seedRoles: [Role], seedAssignments: [Assign(ProviderOnly)]),
            catalogue,
            new GovernedModelRegistryStub(Routable, ProviderOnly));

        Assert.Null((await notRegistered.ResolveAsync(AiRole.DefaultRoleName)).Model);
        Assert.NotNull((await registered.ResolveAsync(AiRole.DefaultRoleName)).Model);
    }

    // ---------------------------------------------------------------- 6. removing from B removes eligibility

    [Fact]
    public void Invariant6_Registration_is_membership_and_removing_it_removes_eligibility()
    {
        // The registry is membership and nothing else: it does not infer support, and it does not keep
        // a model because a provider offers one. Removing an id from B removes eligibility with no
        // change to any provider capability data.
        var registry = new GovernedModelRegistryStub(Routable, ProviderOnly);
        Assert.True(registry.TryGetModel(ProviderOnly, out _));

        var narrowed = new GovernedModelRegistryStub(Routable);
        Assert.False(narrowed.TryGetModel(ProviderOnly, out var removed));
        Assert.Null(removed);

        // CONTROL: the narrowing did not empty the registry — so the assertion above is a removal and
        // not an empty registry that would refuse everything.
        Assert.True(narrowed.TryGetModel(Routable, out _));
        Assert.Equal(1, narrowed.Count);
    }

    // ---------------------------------------------------------------- 7. pricing is not authorization

    [Fact]
    public void Invariant7_Pricing_on_a_registration_does_not_by_itself_authorize_routing()
    {
        // A registration carries pricing metadata. Pricing is an association ON a registration; it is
        // not a registration, and a model with prices and no registry entry is still unroutable.
        var priced = new AiModelRegistration
        {
            ModelId = ProviderOnly,
            ProviderId = "openai",
            DisplayName = ProviderOnly,
            GovernanceRationale = "Has pricing metadata and is deliberately NOT registered.",
            InputCostPer1kTokens = 0.0025m,
            OutputCostPer1kTokens = 0.01m,
            CostCurrency = "USD",
        };

        Assert.NotNull(priced.InputCostPer1kTokens);          // the pricing IS present
        Assert.False(new GovernedModelRegistryStub(Routable).TryGetModel(priced.ModelId, out _));

        // ...and the model is routable only once it is a MEMBER, not because it is priced.
        Assert.True(new GovernedModelRegistryStub(Routable, ProviderOnly).TryGetModel(priced.ModelId, out _));
    }

    /// <summary>The provider side of the boundary: what the implementation SUPPORTS.</summary>
    private sealed class Catalogue(params ModelDescriptor[] models) : IModelCatalog
    {
        public Task<IReadOnlyList<ModelDescriptor>> ListAsync(ModelQuery query, CancellationToken ct = default)
            => Task.FromResult<IReadOnlyList<ModelDescriptor>>(models);
    }
}
