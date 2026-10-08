using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.Core.Operations;
using Nexus.Intelligence.Core.Registry;
using Nexus.Intelligence.Core.Routing;
using Nexus.Platform.Contracts.Models;
using Nexus.Platform.Core.Models;
using Xunit;

namespace Nexus.Intelligence.Tests.Operations;

/// <summary>
/// W10.7 — the AI Head's published operations read model, and the seven distinctions it exists to keep.
/// </summary>
/// <remarks>
/// <para>
/// <b>These are sensitivity tests, not shape tests.</b> Each one asserts that a pair of facts a reader
/// could reasonably collapse stays apart in the published document: provider-supported versus
/// governed-routable, implemented versus deployed, declared health versus observed health, absent
/// telemetry versus a measured zero. A test that only asserted the document's field names would pass on
/// a projection that collapsed every one of them.
/// </para>
/// <para>
/// The figures this suite asserts against are the ones a <em>composed</em> estate produces; the
/// end-to-end publication over the real container is proven separately, because a unit test cannot show
/// that the host's own binding path reaches this projection.
/// </para>
/// </remarks>
public sealed class AiOperationsPublicationTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 8, 10, 0, 0, TimeSpan.Zero);

    // --- TASK 2 / TASK 3: the two model surfaces -------------------------------------------------------

    [Fact]
    public async Task A_provider_supported_model_is_never_reported_as_routable()
    {
        // The W10.7A decision, as an assertion. gpt-4o is in the provider's catalogue and absent from
        // the governed registry, and that must not be read as routable by anything downstream.
        var payload = await Project(
            registry: Registry(models: ["openai:gpt-4.1"]),
            catalogue: Catalogue("openai:gpt-4.1", "openai:gpt-4o"));

        var supportOnly = payload.Models.Single(m => m.ModelId == "openai:gpt-4o");

        Assert.True(supportOnly.ProviderSupported);
        Assert.False(supportOnly.GovernedRegistered);
        Assert.False(supportOnly.RoutableByConfiguration);
        Assert.Equal(
            AiModelAuthorityClassification.ProviderSupportedNotRegisteredForRouting,
            supportOnly.Classification);
    }

    [Fact]
    public async Task A_registered_but_unapproved_model_is_not_routable()
    {
        var payload = await Project(
            registry: Registry(models: ["openai:gpt-4.1"]),
            catalogue: Catalogue("openai:gpt-4.1"));

        var registered = payload.Models.Single();

        Assert.True(registered.GovernedRegistered);
        Assert.False(registered.RoutableByConfiguration);
        Assert.Equal(
            AiModelAuthorityClassification.GovernedRegisteredNotRoutable,
            registered.Classification);
    }

    [Fact]
    public async Task The_four_model_counts_are_reported_separately_and_never_merged()
    {
        var payload = await Project(
            registry: Registry(models: ["openai:gpt-4.1", "openai:gpt-4.1-mini"]),
            catalogue: Catalogue("openai:gpt-4.1", "openai:gpt-4.1-mini", "openai:gpt-4o"));

        Assert.Equal(3, payload.ModelAuthority.ProviderSupportedModels);
        Assert.Equal(2, payload.ModelAuthority.GovernedRegisteredModels);
        Assert.Equal(0, payload.ModelAuthority.RoutableModels);
        Assert.Equal(1, payload.ModelAuthority.ProviderSupportedOnlyModels);

        // The support-only count is stated by the producer, never left for a consumer to subtract.
        Assert.NotEqual(
            payload.ModelAuthority.ProviderSupportedModels - payload.ModelAuthority.GovernedRegisteredModels,
            payload.ModelAuthority.RoutableModels);
    }

    // --- TASK 3: provider axes -------------------------------------------------------------------------

    [Fact]
    public async Task A_placeholder_provider_is_not_reported_as_implemented_or_deployed()
    {
        var payload = await Project(
            registry: Registry(),
            catalogue: [],
            adapters:
            [
                Adapter("anthropic", AiProviderImplementationState.Placeholder, deployed: false, configured: false),
                Adapter("openai", AiProviderImplementationState.Implemented, deployed: true, configured: true),
            ]);

        var anthropic = payload.Providers.Single(p => p.ProviderId == "anthropic");

        Assert.Equal(AiProviderImplementationState.Placeholder, anthropic.Implementation);
        Assert.False(anthropic.Deployed);
        Assert.False(anthropic.Configured);
        Assert.False(anthropic.RuntimeApplicable);
        Assert.False(anthropic.Enabled);
        Assert.False(anthropic.RoutableByConfiguration);

        // The row is PRESENT. Omitting it would read as "no such adapter was ever written", and the
        // estate's whole point in carrying a placeholder is that somebody must be able to see it.
        Assert.NotEmpty(payload.Providers);
    }

    [Fact]
    public async Task A_disabled_or_unapproved_provider_is_never_routable()
    {
        var payload = await Project(
            registry: Registry(providers: [Provider("openai", enabled: false, approval: "Unregistered")]),
            catalogue: []);

        var openai = payload.Providers.Single();

        Assert.False(openai.Enabled);
        Assert.Equal("Unregistered", openai.Approval);
        Assert.False(openai.RoutableByConfiguration);
    }

    [Fact]
    public async Task An_approved_enabled_provider_IS_routable_so_the_previous_test_is_not_vacuous()
    {
        // The paired control. Without this, the test above would pass on a projection that answered
        // false unconditionally, which proves nothing about the axis.
        var payload = await Project(
            registry: Registry(
                providers: [Provider("openai", enabled: true, approval: "Approved")],
                models: ["openai:gpt-4.1"],
                modelApproval: "Approved"),
            catalogue: Catalogue("openai:gpt-4.1"));

        Assert.True(payload.Providers.Single().RoutableByConfiguration);
        Assert.True(payload.Models.Single().RoutableByConfiguration);
        Assert.Equal(1, payload.ModelAuthority.RoutableModels);
    }

    // --- TASK 5: health authority ----------------------------------------------------------------------

    [Fact]
    public async Task Declared_health_is_never_reported_as_observed_health()
    {
        var payload = await Project(
            registry: Registry(health: [new AiHealthConfigurationEntry { ProviderId = "openai", State = "Available" }]),
            catalogue: []);

        Assert.Equal("Available", payload.Health.ProviderRows.Single().State);

        // The state is a real declared value; it is simply not an observation, and the document says so
        // twice — once on the row and once on the plane.
        Assert.False(payload.Health.ProviderRows.Single().Observed);
        Assert.False(payload.Health.ProviderHealthObserved);
        Assert.False(payload.Health.ModelHealthObserved);
        Assert.Equal(AiSourceGaps.ProviderHealth, payload.Health.GapId);
    }

    [Fact]
    public async Task A_disabled_probe_is_not_reported_as_running_or_able_to_reach_a_provider()
    {
        var payload = await Project(registry: Registry(), catalogue: []);

        Assert.True(payload.Health.ProbeImplemented);
        Assert.False(payload.Health.ProbeConfiguredEnabled);
        Assert.False(payload.Health.ProbeHosted);
        Assert.False(payload.Health.ProbeCanReachProvider);
        Assert.Null(payload.Health.ProbeIntervalSeconds);
    }

    [Fact]
    public async Task The_host_liveness_route_is_reported_as_observing_nothing()
    {
        var payload = await Project(registry: Registry(), catalogue: []);

        // /health returns a literal. A reader must not be able to read it as AI runtime or provider
        // health, and the two members together are what stops that.
        Assert.Equal(AiHostLivenessBasis.Literal, payload.Health.HostLiveness);
        Assert.False(payload.Health.HostLivenessImpliesRuntimeHealth);
    }

    // --- TASK 6: usage and cost ------------------------------------------------------------------------

    [Fact]
    public async Task Unavailable_usage_and_cost_carry_no_number_a_consumer_could_render_as_zero_spend()
    {
        var payload = await Project(registry: Registry(), catalogue: []);

        Assert.Equal(AiTelemetryState.InProcessOnly, payload.Usage.State);
        Assert.False(payload.Usage.Durable);
        Assert.Equal(AiSourceGaps.Usage, payload.Usage.GapId);

        Assert.Equal(AiTelemetryState.InProcessOnly, payload.Cost.State);
        Assert.False(payload.Cost.Durable);
        Assert.Equal(AiSourceGaps.Cost, payload.Cost.GapId);

        // Neither axis carries a total, a token count or a currency. The only number either one carries
        // is a count of records, and it is zero because a freshly composed process holds none.
        Assert.Equal(0, payload.Usage.RecordsHeld);
        Assert.Equal(0, payload.Cost.RecordsHeld);

        var serialised = AiOperationsDigest.Canonicalize(
            JsonSerializer.SerializeToNode(payload, AiOperationsJson.Canonical));

        Assert.DoesNotContain("\"TotalTokens\"", serialised, StringComparison.Ordinal);
        Assert.DoesNotContain("\"TotalCost\"", serialised, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Pricing_is_reported_as_metadata_and_never_as_a_measured_cost()
    {
        var payload = await Project(registry: Registry(), catalogue: Catalogue("openai:gpt-4.1"));

        Assert.True(payload.Pricing.RatesConfigured);
        Assert.Equal(1, payload.Pricing.RatedModels);

        // The rate is a vendor catalogue figure carried on the model row, and the pricing plane says so.
        var model = payload.Models.Single();
        Assert.Equal("0.002", model.CatalogueCostPer1kIn);
    }

    [Fact]
    public async Task An_absent_rate_is_null_and_never_the_string_zero()
    {
        var payload = await Project(registry: Registry(models: ["openai:unrated"]), catalogue: []);

        var model = payload.Models.Single();

        Assert.Null(model.CatalogueCostPer1kIn);
        Assert.Null(model.CatalogueCostPer1kOut);
        Assert.False(payload.Pricing.RatesConfigured);
    }

    // --- TASK 7: routing ----------------------------------------------------------------------------

    [Fact]
    public async Task A_configured_fallback_is_never_reported_as_an_observed_failover()
    {
        var payload = await Project(registry: Registry(), catalogue: []);

        Assert.Equal(1, payload.Routing.ConfiguredFallbackDepth);

        // Nothing has run, and the document says that in its own member rather than by leaving the
        // configured depth to be read as evidence.
        Assert.False(payload.Routing.ObservedFailover.ExecutionsObserved);
        Assert.Equal(0, payload.Routing.ObservedFailover.FallbackAttempts);
    }

    [Fact]
    public async Task Every_registered_model_is_listed_as_a_route_with_its_ineligibility_named()
    {
        var payload = await Project(registry: Registry(models: ["openai:gpt-4.1"]), catalogue: []);

        var route = Assert.Single(payload.Routing.ConfiguredRoutes);

        Assert.Equal("openai:gpt-4.1", route.ModelId);
        Assert.False(route.Eligible);
        Assert.Equal("MODEL_DISABLED", route.IneligibilityReason);
    }

    // --- TASK 9: the security boundary ----------------------------------------------------------------

    [Fact]
    public async Task The_published_document_carries_the_secret_reference_name_and_never_a_secret()
    {
        var payload = await Project(
            registry: Registry(providers: [Provider("openai", secretReference: "NEXUS_OPENAI_API_KEY")]),
            catalogue: []);

        Assert.Equal("NEXUS_OPENAI_API_KEY", payload.Providers.Single().SecretReferenceName);

        var serialised = AiOperationsDigest.Canonicalize(
            JsonSerializer.SerializeToNode(payload, AiOperationsJson.Canonical));

        // The name is present and nothing shaped like a credential is. A registry cannot carry a value
        // here — its own parse refuses one — so this control proves the publication did not add a path
        // of its own.
        Assert.Contains("NEXUS_OPENAI_API_KEY", serialised, StringComparison.Ordinal);
        Assert.DoesNotContain("sk-", serialised, StringComparison.Ordinal);
        Assert.DoesNotContain("Bearer ", serialised, StringComparison.Ordinal);
        Assert.DoesNotContain("password", serialised, StringComparison.OrdinalIgnoreCase);
    }

    // --- The digest -----------------------------------------------------------------------------------

    [Fact]
    public async Task The_digest_excludes_the_observation_instant_and_the_source_revision()
    {
        var publisher = new AiOperationsReadPublisher(await Projection(Registry(), Catalogue()));

        var first = await Publish(publisher, Now);
        var second = await Publish(publisher, Now.AddHours(3));

        Assert.True(first.Published);
        Assert.True(second.Published);

        // Byte-identical digest across three hours, because the facts did not change.
        Assert.Equal(first.PayloadDigest, second.PayloadDigest);
    }

    [Fact]
    public async Task The_digest_changes_when_the_facts_change()
    {
        using var first = new PublicationDirectory();
        using var second = new PublicationDirectory();

        var publisherA = new AiOperationsReadPublisher(await Projection(Registry(), Catalogue("openai:gpt-4.1")));
        var publisherB = new AiOperationsReadPublisher(await Projection(Registry(), Catalogue()));

        var outcomeA = await publisherA.PublishAsync(first.Path, Now);
        var outcomeB = await publisherB.PublishAsync(second.Path, Now);

        Assert.NotEqual(outcomeA.PayloadDigest, outcomeB.PayloadDigest);
    }

    [Fact]
    public async Task The_canonical_form_is_key_sorted_so_an_independent_consumer_can_reproduce_it()
    {
        var publisher = new AiOperationsReadPublisher(await Projection(Registry(), Catalogue()));

        using var directory = new PublicationDirectory();

        var outcome = await publisher.PublishAsync(directory.Path, Now);

        // Re-read the PUBLISHED payload, re-canonicalise it exactly as a consumer would, and confirm the
        // producer's stated digest describes those bytes. This is the property that makes the digest
        // worth carrying: a consumer verifies rather than trusts.
        var text = File.ReadAllText(outcome.Path!).TrimStart('﻿');
        var document = JsonDocument.Parse(text);

        var payload = document.RootElement.GetProperty("Payload");

        var canonical = AiOperationsDigest.Canonicalize(JsonNode.Parse(payload.GetRawText()));

        Assert.True(AiOperationsDigest.Verifies(canonical, outcome.PayloadDigest));

        // And the canonical form is genuinely sorted: every object's keys ascend ordinally.
        AssertCanonicalObjectsAreSorted(canonical);
    }

    // --- The publisher --------------------------------------------------------------------------------

    [Fact]
    public async Task Publishing_nothing_new_is_still_a_publication_and_the_envelope_moves()
    {
        var publisher = new AiOperationsReadPublisher(await Projection(Registry(), Catalogue()));

        using var directory = new PublicationDirectory();

        var first = await publisher.PublishAsync(directory.Path, Now);
        var digestAfterFirst = AiOperationsReadPublisher.PublishedDigest(directory.Path);

        var second = await publisher.PublishAsync(directory.Path, Now.AddMinutes(5));

        Assert.True(second.Published);
        Assert.Equal(first.PayloadDigest, digestAfterFirst);

        // The publisher always writes. Idempotency is semantic — the caller compares digests — and a
        // publisher that skipped would be trusting its own comparison instead of its caller's.
        var observed = JsonDocument.Parse(File.ReadAllText(second.Path!).TrimStart('﻿'))
            .RootElement.GetProperty("Source").GetProperty("ObservedAt").GetString();

        Assert.Equal(Now.AddMinutes(5).ToString("O", CultureInfo.InvariantCulture), observed);
    }

    [Fact]
    public async Task A_relative_destination_is_refused_rather_than_resolved()
    {
        var publisher = new AiOperationsReadPublisher(await Projection(Registry(), Catalogue()));

        var outcome = await publisher.PublishAsync("publication", Now);

        Assert.False(outcome.Published);
        Assert.Contains("absolute", outcome.Reason, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_blank_destination_is_refused_rather_than_guessed()
    {
        var publisher = new AiOperationsReadPublisher(await Projection(Registry(), Catalogue()));

        var outcome = await publisher.PublishAsync("   ", Now);

        Assert.False(outcome.Published);
        Assert.Contains("never guessed", outcome.Reason, StringComparison.Ordinal);
    }

    [Fact]
    public async Task No_staging_file_survives_a_successful_publication()
    {
        var publisher = new AiOperationsReadPublisher(await Projection(Registry(), Catalogue()));

        using var directory = new PublicationDirectory();

        await publisher.PublishAsync(directory.Path, Now);

        Assert.Empty(Directory.GetFiles(directory.Path, "*.staging"));
        Assert.Single(Directory.GetFiles(directory.Path));
    }

    // --- Fixtures -------------------------------------------------------------------------------------

    private static async Task<AiOperationsReadModelPayload> Project(
        AiRegistryConfiguration registry,
        IReadOnlyList<ModelDescriptor> catalogue,
        IReadOnlyList<AiProviderAdapterObservation>? adapters = null)
        => await (await Projection(registry, catalogue, adapters)).ProjectAsync();

    private static async Task<AiOperationsPublicationProjection> Projection(
        AiRegistryConfiguration registry,
        IReadOnlyList<ModelDescriptor> catalogue,
        IReadOnlyList<AiProviderAdapterObservation>? adapters = null)
    {
        var operations = new AiOperationsConfiguration();

        var observation = new AiRuntimeObservation
        {
            HostExecutablePresent = true,
            HostName = "test-host",
            HttpSurfacePresent = true,
            MappedApiPrefixes = [new AiMappedApiSurface("/health", "host-liveness")],
            Registrations = [],
            ProviderAdapters = adapters
                ?? [Adapter("openai", AiProviderImplementationState.Implemented, deployed: true, configured: true)],
            HealthProbeServiceHosted = false,
        };

        return new AiOperationsPublicationProjection(
            registry,
            operations,
            operations.BudgetPolicy(),
            AiRoutingPolicy.Default,
            new StubModelCatalog(catalogue),
            new InMemoryAiHealthSnapshotStore(SeededAiHealthSnapshot.From(registry, Now)),
            new InMemoryAiOperationsLedger(),
            new InMemoryAiOperationsLedger(),
            observation,
            "test-revision");
    }

    private static async Task<AiOperationsPublishOutcome> Publish(
        AiOperationsReadPublisher publisher,
        DateTimeOffset observedAt)
        => await publisher.PublishAsync(TemporaryDirectory(), observedAt);

    private static string TemporaryDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "ai-ops-" + Guid.NewGuid().ToString("N")[..10]);
        Directory.CreateDirectory(path);
        return path;
    }

    private static AiRegistryConfiguration Registry(
        IReadOnlyList<AiProviderConfigurationEntry>? providers = null,
        IReadOnlyList<string>? models = null,
        string modelApproval = "Unregistered",
        IReadOnlyList<AiHealthConfigurationEntry>? health = null)
        => new()
        {
            Providers = [.. providers ?? [Provider("openai", enabled: false, approval: "Unregistered")]],
            Models = [.. (models ?? []).Select(id => new AiModelConfigurationEntry
            {
                ModelId = id,
                ProviderId = "openai",
                DisplayName = id,
                Capabilities = [],
                Enabled = modelApproval == "Approved",
                Approval = modelApproval,
                GovernanceRationale = "Fixture.",
            })],
            Health = [.. health ?? []],
        };

    private static AiProviderConfigurationEntry Provider(
        string id,
        bool enabled = false,
        string approval = "Unregistered",
        string? secretReference = null)
        => new()
        {
            ProviderId = id,
            DisplayName = id,
            AdapterIdentity = $"test.{id}",
            Enabled = enabled,
            Approval = approval,
            PermitsRemoteEgress = true,
            SecretReference = secretReference,
            GovernanceRationale = "Fixture.",
        };

    private static IReadOnlyList<ModelDescriptor> Catalogue(params string[] modelIds)
        => [.. modelIds.Select(id => new ModelDescriptor(
            id,
            "openai",
            ModelCapabilities.Chat | ModelCapabilities.ToolUse,
            128000,
            0.002m,
            0.008m,
            LatencyClass.Medium))];

    private static AiProviderAdapterObservation Adapter(
        string providerId,
        AiProviderImplementationState implementation,
        bool deployed,
        bool configured)
        => new()
        {
            ProviderId = providerId,
            AssemblyName = $"Nexus.Platform.Providers.{providerId}",
            Implementation = implementation,
            ServingTypeName = implementation is AiProviderImplementationState.Implemented ? "Test.Gateway" : null,
            Configured = configured,
            RuntimeApplicable = deployed,
            Deployed = deployed,
        };

    /// <summary>Asserts that every object in a canonical JSON string has ordinally ascending keys.</summary>
    /// <remarks>
    /// A scanner rather than a deserialiser on purpose. Deserialising would let the serializer choose the
    /// order it presented, which is the exact property under test: this asserts on the characters a
    /// consumer in another language would receive, and the last key seen is kept per nesting level
    /// because a nested object's keys must not be compared against its parent's.
    /// </remarks>
    private static void AssertCanonicalObjectsAreSorted(string canonical)
    {
        // One entry per open object; the value is the last key seen at that level.
        var openObjects = new Stack<string>();

        var index = 0;

        while (index < canonical.Length)
        {
            switch (canonical[index])
            {
                case '{':
                    openObjects.Push(string.Empty);
                    index++;
                    continue;

                case '}':
                    Assert.NotEmpty(openObjects);
                    openObjects.Pop();
                    index++;
                    continue;

                case '"' when openObjects.Count > 0:
                    var end = index + 1;

                    while (end < canonical.Length && canonical[end] != '"')
                    {
                        end += canonical[end] == '\\' ? 2 : 1;
                    }

                    // A key is a string immediately followed by a colon. A string VALUE is not, and
                    // treating one as a key is how a scanner like this reports a false failure.
                    if (end + 1 < canonical.Length && canonical[end + 1] == ':')
                    {
                        var key = canonical[(index + 1)..end];

                        var previous = openObjects.Pop();

                        Assert.True(
                            previous.Length == 0 || string.CompareOrdinal(previous, key) < 0,
                            $"Canonical JSON keys are not ordinally sorted: '{previous}' then '{key}'.");

                        openObjects.Push(key);
                    }

                    index = end + 1;
                    continue;

                default:
                    index++;
                    continue;
            }
        }

        Assert.Empty(openObjects);
    }

    private sealed class StubModelCatalog(IReadOnlyList<ModelDescriptor> descriptors) : IModelCatalog
    {
        public Task<IReadOnlyList<ModelDescriptor>> ListAsync(ModelQuery query, CancellationToken ct = default)
            => Task.FromResult(descriptors);
    }

    private sealed class PublicationDirectory : IDisposable
    {
        public PublicationDirectory()
        {
            Path = TemporaryDirectory();
        }

        public string Path { get; }

        public void Dispose()
        {
            try
            {
                Directory.Delete(Path, recursive: true);
            }
            catch (IOException)
            {
                // Best effort. A temp directory that survives a test run is untidy, not a failure.
            }
        }
    }
}
