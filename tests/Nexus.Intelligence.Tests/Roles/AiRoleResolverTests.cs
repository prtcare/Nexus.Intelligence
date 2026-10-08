using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Roles;
using Nexus.Intelligence.Core.Turns;
using Nexus.Intelligence.Tests.Registry;
using Nexus.Platform.Contracts.Models;
using Xunit;

namespace Nexus.Intelligence.Tests.Roles;

public sealed class AiRoleResolverTests
{
    private static readonly DateTimeOffset AssignedAt = new(2026, 8, 30, 0, 0, 0, TimeSpan.Zero);

    private static readonly ModelDescriptor Gpt41 = new(
        "openai:gpt-4.1",
        "openai",
        ModelCapabilities.Chat | ModelCapabilities.Reasoning | ModelCapabilities.ToolUse |
        ModelCapabilities.Streaming | ModelCapabilities.StructuredOutput | ModelCapabilities.LongContext,
        1_047_576,
        0.002m,
        0.008m,
        LatencyClass.Medium);

    private static readonly ModelDescriptor Gpt40 = new(
        "openai:gpt-4o",
        "openai",
        ModelCapabilities.Chat | ModelCapabilities.Vision | ModelCapabilities.ToolUse | ModelCapabilities.Streaming,
        128_000,
        0.0025m,
        0.01m,
        LatencyClass.Medium);

    private static readonly AiRole DiscussionRole = new(
        AiRole.DefaultRoleName,
        "Default conversational role for the current caller (Developer Chat).");

    private static readonly AiRoleAssignment DiscussionGpt41 = new(
        AiRole.DefaultRoleName,
        "openai:gpt-4.1",
        ModelCapabilities.Chat | ModelCapabilities.Reasoning | ModelCapabilities.ToolUse |
        ModelCapabilities.Streaming | ModelCapabilities.StructuredOutput | ModelCapabilities.LongContext,
        AssignedAt);

    [Fact]
    public async Task ResolveAsync_WithSeededDiscussionAssignment_ResolvesToAssignedModel()
    {
        var store = new InMemoryAiRoleStore(
            seedRoles: [DiscussionRole],
            seedAssignments: [DiscussionGpt41]);
        var resolver = new AiRoleResolver(store, new FakeCatalog(Gpt41, Gpt40), new GovernedModelRegistryStub("openai:gpt-4.1"));

        var resolved = await resolver.ResolveAsync(AiRole.DefaultRoleName);

        // The role and its description come from the store, not from code.
        Assert.Equal(DiscussionRole, resolved.Role);
        Assert.Equal(DiscussionRole.Description, resolved.Role!.Description);
        Assert.NotNull(resolved.Assignment);
        Assert.NotNull(resolved.Model);
        Assert.Equal("openai:gpt-4.1", resolved.Model!.ModelId);
        Assert.Equal("Resolved AiRole 'Discussion' to model 'openai:gpt-4.1'", resolved.Decision.What);
    }

    [Fact]
    public async Task ResolveAsync_WhenAssignedModelMissingFromCatalog_FallsThroughWithoutHardwiringFailure()
    {
        var store = new InMemoryAiRoleStore(
            seedRoles: [DiscussionRole],
            seedAssignments: [DiscussionGpt41 with { ModelId = "openai:gpt-5" }]);
        var resolver = new AiRoleResolver(store, new FakeCatalog(Gpt41, Gpt40), new GovernedModelRegistryStub("openai:gpt-4.1"));

        var resolved = await resolver.ResolveAsync(AiRole.DefaultRoleName);

        Assert.NotNull(resolved.Assignment);
        Assert.Null(resolved.Model);
        Assert.Equal("AiRole 'Discussion' assignment is not resolvable", resolved.Decision.What);
    }

    [Fact]
    public async Task ResolveAsync_WhenAssignedModelLacksRequiredCapability_FallsThrough()
    {
        // gpt-4o has no Reasoning capability, which the role requires.
        var store = new InMemoryAiRoleStore(
            seedRoles: [DiscussionRole],
            seedAssignments: [DiscussionGpt41 with { ModelId = Gpt40.ModelId }]);
        var resolver = new AiRoleResolver(store, new FakeCatalog(Gpt41, Gpt40), new GovernedModelRegistryStub("openai:gpt-4.1"));

        var resolved = await resolver.ResolveAsync(AiRole.DefaultRoleName);

        Assert.NotNull(resolved.Assignment);
        Assert.Null(resolved.Model);
    }

    [Fact]
    public async Task ResolveAsync_WhenRoleHasNoAssignment_FallsThrough()
    {
        // The role is registered, but no assignment binds it to a model.
        var store = new InMemoryAiRoleStore(seedRoles: [DiscussionRole]);
        var resolver = new AiRoleResolver(store, new FakeCatalog(Gpt41, Gpt40), new GovernedModelRegistryStub("openai:gpt-4.1"));

        var resolved = await resolver.ResolveAsync(AiRole.DefaultRoleName);

        Assert.NotNull(resolved.Role);
        Assert.Null(resolved.Assignment);
        Assert.Null(resolved.Model);
        Assert.Equal("AiRole 'Discussion' has no active assignment", resolved.Decision.What);
    }

    [Fact]
    public async Task ResolveAsync_WhenRoleNeverRegistered_FallsThrough()
    {
        var resolver = new AiRoleResolver(new InMemoryAiRoleStore(), new FakeCatalog(Gpt41, Gpt40), new GovernedModelRegistryStub("openai:gpt-4.1"));

        var resolved = await resolver.ResolveAsync(AiRole.DefaultRoleName);

        Assert.Null(resolved.Role);
        Assert.Null(resolved.Assignment);
        Assert.Null(resolved.Model);
        Assert.Equal("AiRole 'Discussion' is not registered", resolved.Decision.What);
    }

    [Fact]
    public async Task UpsertAsync_SwappingRoleAssignment_IsConfigNotCode()
    {
        var store = new InMemoryAiRoleStore(seedAssignments: [DiscussionGpt41]);

        await store.UpsertAsync(new AiRoleAssignment(
            AiRole.DefaultRoleName,
            "openai:gpt-4o",
            ModelCapabilities.Chat,
            AssignedAt));

        var active = await store.GetAsync(AiRole.DefaultRoleName);

        Assert.NotNull(active);
        Assert.Equal("openai:gpt-4o", active!.ModelId);
        Assert.Single(await store.ListAsync());
    }

    [Fact]
    public async Task UpsertRoleAsync_PersistsAndReplacesRole_ThroughData()
    {
        var store = new InMemoryAiRoleStore();

        await store.UpsertRoleAsync(DiscussionRole);

        Assert.Equal(DiscussionRole, await store.GetRoleAsync(AiRole.DefaultRoleName));

        await store.UpsertRoleAsync(DiscussionRole with { Description = "Updated description via data." });

        var updated = await store.GetRoleAsync(AiRole.DefaultRoleName);
        Assert.Equal("Updated description via data.", updated!.Description);
    }

    /// <summary>
    /// W7D TASK 9: the resolution surfaces the assignment's model and stops there.
    /// </summary>
    /// <remarks>
    /// <para>
    /// This test replaces <c>ResolvedRoleModel_FeedsModelSelectorAsHint_AndIsSelected</c>, which asserted
    /// the opposite: that the resolved model became <c>TurnConstraints.ModelHint</c> and that
    /// <c>ModelSelector</c> then selected it. That is the behaviour W7D removed — the role was a model pin
    /// applied inside the AI Head, invisible to the caller and indistinguishable in the audit record from
    /// a capability-based choice. <c>ModelSelector</c> no longer exists, so the old assertion cannot even
    /// be written.
    /// </para>
    /// <para>
    /// <b>The replacement asserts the boundary that remains.</b> The resolution still reports the model an
    /// operator assigned, which is what makes the assignment reviewable; and the model it reports is the
    /// same one the store holds, so the reporting has not silently substituted something else. What the
    /// pipeline does with it is asserted where it belongs — in the live-path tests, which prove the
    /// reported model is <em>not</em> applied to the turn.
    /// </para>
    /// </remarks>
    [Fact]
    public async Task ResolveAsync_SurfacesAssignedModelAsEvidence_WithoutProducingARoute()
    {
        var store = new InMemoryAiRoleStore(
            seedRoles: [DiscussionRole],
            seedAssignments: [DiscussionGpt41]);
        var resolver = new AiRoleResolver(store, new FakeCatalog(Gpt41, Gpt40), new GovernedModelRegistryStub("openai:gpt-4.1"));

        var resolved = await resolver.ResolveAsync(AiRole.DefaultRoleName);

        // CONTROL: the assignment is reported rather than dropped, and it is the stored value.
        Assert.Equal(DiscussionGpt41.ModelId, resolved.Model!.ModelId);
        Assert.Equal(DiscussionGpt41.ModelId, resolved.Assignment!.ModelId);

        // NEGATIVE: reporting a model produced no model selection. There is no selection to inspect, and
        // the record that describes the resolution says it resolved a role — not that it chose a route.
        Assert.Equal("Resolved AiRole 'Discussion' to model 'openai:gpt-4.1'", resolved.Decision.What);
        Assert.DoesNotContain("Selected", resolved.Decision.What, StringComparison.Ordinal);
    }

    private sealed class FakeCatalog(params ModelDescriptor[] models) : IModelCatalog
    {
        public Task<IReadOnlyList<ModelDescriptor>> ListAsync(ModelQuery query, CancellationToken ct = default)
            => Task.FromResult<IReadOnlyList<ModelDescriptor>>(models);
    }
}
