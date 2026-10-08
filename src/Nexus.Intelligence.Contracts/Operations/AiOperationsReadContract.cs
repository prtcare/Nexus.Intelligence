namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The identity of the AI Head's published operations read model.
/// </summary>
/// <remarks>
/// <para>
/// <b>A versioned document rather than a live endpoint, and the reason is ownership.</b> Nexus Atlas
/// reads the estate's operational truth through published documents. The AI Head owns this document
/// because the AI Head owns every fact in it; Atlas consumes it and must never be given a way to ask
/// the AI Head a question, invoke a provider, or reach a model. Publishing to a file is what makes that
/// boundary structural: the AI Head writes, Atlas reads, and neither holds a reference to the other.
/// </para>
/// <para>
/// <b>The name and the version are separate members.</b> A consumer must be able to tell <em>which</em>
/// document it is holding and <em>which revision of the shape</em> that document has, independently.
/// Collapsing them into one string would make "an AI operations read model I do not understand" and "a
/// document of a different kind entirely" the same refusal, which are different findings an operator
/// would want distinguished.
/// </para>
/// </remarks>
public static class AiOperationsReadContract
{
    /// <summary>
    /// The schema identity, and the whole string a consumer keys on.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>One string carrying both the family and the major version, because that is what the estate's
    /// existing consumers already key on.</b> Nexus Atlas reads three published read models today
    /// (Delivery, DevelopmentControl and Platform runtime) through one loader whose registry maps the
    /// entire <c>SchemaVersion</c> string to an adapter. A second naming convention here would be a
    /// second mechanism to read, which the directive forbids.
    /// </para>
    /// <para>
    /// The version being <em>in</em> the identity is what makes an unrecognised version a refusal: the
    /// registry lookup misses and the consumer reports <c>unsupported</c>, rather than parsing a shape
    /// it does not implement and rendering whatever happened to line up.
    /// </para>
    /// </remarks>
    public const string SchemaVersion = "nexus.ai-operations-read-model.v1";

    /// <summary>The family name alone, without the version suffix.</summary>
    /// <remarks>
    /// The consumer's own name for this authority. It is what Atlas's adapter is registered under and
    /// what its loader checks its document against, so a Delivery document that somehow reached the AI
    /// loader is refused by name rather than adapted into an empty AI model.
    /// </remarks>
    public const string ContractType = "nexus.ai-operations-read-model";

    /// <summary>The accountable owner of every fact in this document.</summary>
    public const string Authority = "AI Head";

    /// <summary>
    /// What this publication is a statement about within the authority.
    /// </summary>
    /// <remarks>
    /// The AI Head owns several surfaces and will own more. This names the one this document describes,
    /// so a consumer holding two documents from one authority can tell them apart without reading
    /// either payload — and so a second AI Head publication can be added without changing this one.
    /// </remarks>
    public const string SourceId = "ai-operations";

    /// <summary>The file a publication writes, and the file a consumer looks for.</summary>
    /// <remarks>
    /// The major version is in the filename on purpose. A v2 document will not be found where a v1
    /// consumer looks, so a version the consumer cannot read surfaces as <c>Missing</c> — an absence —
    /// rather than as a document that parses into half a model. The two are different operational
    /// findings, and the filename is what keeps them apart. It is the filename the estate's three
    /// existing publications already use for their own contracts.
    /// </remarks>
    public const string DocumentFileName = "ai-operations-read-model.v1.json";
}

/// <summary>
/// The envelope a publication writes: schema identity, publication metadata, and the payload.
/// </summary>
/// <remarks>
/// <para>
/// <b>The payload is the semantic identity; the envelope is the publication's own record.</b>
/// <see cref="AiOperationsDigest.Of"/> accepts only the payload, so the two instants on
/// <see cref="Source"/> — which change on every publish — cannot make two semantically identical
/// publications look different. That is the whole reason the digest exists: an operator asking "has
/// anything changed" must get the answer the content gives, not the answer the clock gives.
/// </para>
/// <para>
/// <b>Three members and no more, because that is what the estate's consumers read.</b> The published
/// envelope is a shape three authorities already use and one Atlas loader already validates; adding a
/// fourth member here would be a shape the loader does not know about.
/// </para>
/// </remarks>
public sealed record AiOperationsReadModelDocument(
    string SchemaVersion,
    AiOperationsReadSource Source,
    AiOperationsReadModelPayload Payload);

/// <summary>
/// The publication's own record: who published it, from where, when, and the digest of what.
/// </summary>
/// <remarks>
/// <para>
/// <b>Every member here is outside the semantic digest, and that is enforced by construction rather
/// than by filtering.</b> <see cref="AiOperationsDigest.Of"/> accepts only
/// <see cref="AiOperationsReadModelPayload"/>, so no field of this type can enter the digest even by
/// mistake. The two instants move on every publish; the digest does not, unless the facts did.
/// </para>
/// <para>
/// <b>The shape is the estate's existing published envelope, not a new one.</b> Nexus Atlas reads
/// three published read models through a single loader that requires exactly these members, and a
/// fourth authority that spelled them differently would need a second loader — which the directive
/// forbids and which would be a worse outcome than conforming.
/// </para>
/// <para>
/// <b>No member of this type may ever carry a credential.</b> The payload is written to a file that a
/// separately-owned product reads. The type's own contract is that it can describe a provider's
/// configuration <em>state</em> without describing the configuration's secret half; see
/// <see cref="AiProviderOperationsView.SecretReferenceName"/> for the one place a secret is referenced
/// and how.
/// </para>
/// </remarks>
public sealed record AiOperationsReadSource(
    /// <summary>The schema identity this document claims. See <see cref="AiOperationsReadContract.SchemaVersion"/>.</summary>
    string ContractVersion,

    /// <summary>The accountable owner. See <see cref="AiOperationsReadContract.Authority"/>.</summary>
    string Authority,

    /// <summary>
    /// What this publication is a statement about, within the authority.
    /// </summary>
    /// <remarks>
    /// The AI Head owns several surfaces; this names which one the document describes, so a consumer
    /// holding two documents from one authority can tell them apart without reading either payload.
    /// </remarks>
    string SourceId,

    /// <summary>
    /// The AI Head source revision this publication was produced from.
    /// </summary>
    /// <remarks>
    /// A build identity, not a semantic one. A rebuild that produces the same operational facts is the
    /// same document, so this is outside the digest.
    /// </remarks>
    string SourceRevision,

    /// <summary>
    /// When the AI Head observed the facts in this document, ISO-8601 round-trip form.
    /// </summary>
    /// <remarks>
    /// <b>Outside the semantic digest, on purpose.</b> Re-publishing unchanged facts at a later instant
    /// must not produce a different document, or a consumer that keys on the digest would treat the
    /// estate as changed every time the publisher ran.
    /// </remarks>
    string ObservedAt,

    /// <summary>When the document was written. Equal to <c>ObservedAt</c> for a synchronous projection.</summary>
    string PublishedAt,

    /// <summary>The digest of <c>Payload</c> alone. See <see cref="AiOperationsDigest"/>.</summary>
    string PayloadDigest);

/// <summary>
/// The operational facts the AI Head publishes.
/// </summary>
/// <remarks>
/// <para>
/// <b>Independent axes, and no member called <c>Status</c>.</b> The directive forbids collapsing this
/// document into one verdict, and the prohibition is answered structurally rather than by discipline:
/// there is no field for a consumer to over-read. A provider is described by eight orthogonal facts
/// (implemented, configured, registered, enabled, approved, routable, runtime-applicable, health
/// observed); a model by its catalogue membership, its registry membership and its own governance
/// state; the runtime, the health plane, usage and cost each by their own type. A consumer that wants
/// "is AI green" must decide for itself which of those it means, which is the point.
/// </para>
/// <para>
/// <b>Absence is represented as absence.</b> No member of this document defaults an unmeasured value
/// to zero. Where the estate has no telemetry, the relevant member says so by name rather than by
/// carrying a number that would read as a measurement.
/// </para>
/// </remarks>
public sealed record AiOperationsReadModelPayload
{
    /// <summary>The providers, on every axis.</summary>
    public required IReadOnlyList<AiProviderOperationsView> Providers { get; init; }

    /// <summary>The models, on every axis.</summary>
    public required IReadOnlyList<AiModelOperationsView> Models { get; init; }

    /// <summary>The two model surfaces and how they relate, stated as counts.</summary>
    /// <remarks>
    /// Counts rather than only rows, because "how many models are provider-supported but not registered
    /// for routing" is the question W10.7A's decision is about and it should be answerable without a
    /// consumer re-deriving it — while the rows above remain the authority for <em>which</em> ones.
    /// </remarks>
    public required AiModelAuthoritySummary ModelAuthority { get; init; }

    /// <summary>What routing is configured to do, and what it has been observed to do.</summary>
    public required AiRoutingInventory Routing { get; init; }

    /// <summary>The runtime units the estate composes, and what state each is in.</summary>
    public required AiRuntimeInventory Runtime { get; init; }

    /// <summary>The health plane: what is observed, what is only declared, and what is not observed.</summary>
    public required AiHealthAuthority Health { get; init; }

    /// <summary>Whether usage telemetry exists, and if not, why not.</summary>
    public required AiTelemetryAvailability Usage { get; init; }

    /// <summary>Whether cost telemetry exists, and if not, why not.</summary>
    public required AiTelemetryAvailability Cost { get; init; }

    /// <summary>The pricing metadata the estate holds, which is not a cost measurement.</summary>
    public required AiPricingAuthority Pricing { get; init; }

    /// <summary>
    /// Every source gap this publication is carrying, by identifier.
    /// </summary>
    /// <remarks>
    /// Carried in the document rather than only in a report, so that a consumer rendering an unavailable
    /// fact can say <em>why</em> it is unavailable without holding a second artefact that could drift
    /// from this one.
    /// </remarks>
    public required IReadOnlyList<AiSourceGap> SourceGaps { get; init; }
}

/// <summary>One provider, on every axis that is independent of the others.</summary>
/// <remarks>
/// <para>
/// <b>Eight axes, and no two of them are the same question.</b> The directive requires that a provider
/// implementation existing is not read as the provider being available, configured, enabled, routable,
/// or healthy. Each member below answers exactly one of those, and a reader that wants a verdict must
/// combine them — which is the design, not an inconvenience.
/// </para>
/// <para>
/// <b>The axes are deliberately not ordered into a lifecycle.</b> A provider can be implemented and
/// not configured (<c>anthropic</c>), configured and not enabled (<c>openai</c>), or enabled and not
/// healthy. Nothing here implies that one axis entails the next.
/// </para>
/// </remarks>
public sealed record AiProviderOperationsView
{
    /// <summary>The provider identifier, as the registry spells it.</summary>
    public required string ProviderId { get; init; }

    /// <summary>A human-readable name, where one is declared.</summary>
    public string? DisplayName { get; init; }

    /// <summary>
    /// What exists in code for this provider. Independent of every configuration axis.
    /// </summary>
    /// <remarks>
    /// <see cref="AiProviderImplementationState.Implemented"/> means a serving adapter type exists and
    /// is referenced by the host. <see cref="AiProviderImplementationState.Placeholder"/> means an
    /// assembly exists whose only member is a declaration of intent — an interface with no
    /// implementation and a TODO. <see cref="AiProviderImplementationState.Absent"/> means nothing.
    /// A placeholder is not an implementation, and this member is what keeps them apart.
    /// </remarks>
    public required AiProviderImplementationState Implementation { get; init; }

    /// <summary>
    /// The provider's own configuration section is present and bound by the host.
    /// </summary>
    /// <remarks>
    /// Distinct from <see cref="RegisteredForRouting"/>. A provider can carry configuration the routing
    /// registry does not know about — a catalogue without a registration — and the estate must be able
    /// to say so rather than reporting the union as one fact.
    /// </remarks>
    public required bool Configured { get; init; }

    /// <summary>The provider appears in the governed registry (<c>Ai:Registry:Providers</c>).</summary>
    public required bool RegisteredForRouting { get; init; }

    /// <summary>The registry entry's own <c>Enabled</c> flag.</summary>
    public required bool Enabled { get; init; }

    /// <summary>The registry entry's approval status, by name. Unregistered refuses.</summary>
    public required string Approval { get; init; }

    /// <summary>
    /// A governed route could reach this provider as the registry stands.
    /// </summary>
    /// <remarks>
    /// <b>Derived from configuration, and labelled as such.</b> This is the registry's own determination
    /// — registered, enabled, approved, egress permitted — and it is emphatically <em>not</em> evidence
    /// that a request reached the provider. See <see cref="AiRoutingInventory"/> for the execution
    /// evidence, which on this estate is absent and says so.
    /// </remarks>
    public required bool RoutableByConfiguration { get; init; }

    /// <summary>
    /// The host's composition root composes this provider's adapter.
    /// </summary>
    /// <remarks>
    /// A provider can be implemented in the repository and not composed by the running host. Reporting
    /// the two as one fact would let a repository-wide inventory stand in for a runtime one.
    /// </remarks>
    public required bool RuntimeApplicable { get; init; }

    /// <summary>
    /// The provider's adapter assembly is in the host's own deployment closure.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>A separate axis from <see cref="Implementation"/>, because "the estate ships it" and "the host
    /// runs it" are different claims.</b> A provider can be a placeholder in the repository and not
    /// deployed at all — the host then cannot reach it even in principle, which is a different answer
    /// from one an operator could enable by editing configuration.
    /// </para>
    /// <para>
    /// This is also the member that keeps a provider the host does not deploy from being read as one
    /// that does not exist: the row is present, and this member is false.
    /// </para>
    /// </remarks>
    public required bool Deployed { get; init; }

    /// <summary>
    /// The health plane holds an <em>observed</em> state for this provider.
    /// </summary>
    /// <remarks>
    /// <b>Observed, not declared.</b> The estate's snapshot carries both states an operator wrote down
    /// and states a probe measured, and it marks which is which through its
    /// <c>Source</c>. A declared <c>Unknown</c> is not an observation, and this member is false for it.
    /// </remarks>
    public required bool HealthObserved { get; init; }

    /// <summary>The provider's declared health state, as the health plane currently answers.</summary>
    public required string HealthState { get; init; }

    /// <summary>
    /// The <em>name</em> of the environment variable holding the credential — never its value.
    /// </summary>
    /// <remarks>
    /// <b>The one place a secret is referenced, and it is a reference rather than a secret.</b> The
    /// estate's own registry already validates that this member is shaped like a name and not like a
    /// key, and refuses a registry whose value could be one. Publishing the name is what lets an
    /// operator answer "is this provider pointed at the approved variable" without the document ever
    /// carrying the answer to "what is the key".
    /// </remarks>
    public string? SecretReferenceName { get; init; }

    /// <summary>Whether content may reach this provider over the network at all.</summary>
    public required bool PermitsRemoteEgress { get; init; }

    /// <summary>The declared trust tier, by name.</summary>
    public string? Trust { get; init; }

    /// <summary>The classification ceiling, by name.</summary>
    public string? MaxClassification { get; init; }

    /// <summary>Capability identifiers the provider is declared able to serve.</summary>
    public required IReadOnlyList<string> Capabilities { get; init; }
}

/// <summary>What exists in code for a provider.</summary>
/// <remarks>
/// A closed vocabulary. An unknown implementation state is not representable, because a consumer that
/// met one would have to guess whether to treat it as implemented.
/// </remarks>
[System.Text.Json.Serialization.JsonConverter(
    typeof(System.Text.Json.Serialization.JsonStringEnumConverter<AiProviderImplementationState>))]
public enum AiProviderImplementationState
{
    /// <summary>No code for this provider exists in the composition.</summary>
    Absent = 0,

    /// <summary>
    /// An assembly exists that declares intent and implements nothing.
    /// </summary>
    /// <remarks>
    /// <c>Nexus.Platform.Providers.Anthropic</c> is the estate's instance: one file, an empty interface,
    /// and a TODO naming the work. It builds and it is referenced, so a naive inventory counts it — and
    /// counting it as an implementation is exactly the error this member exists to prevent.
    /// </remarks>
    Placeholder = 1,

    /// <summary>A serving adapter exists and is composed by the host.</summary>
    Implemented = 2,
}

/// <summary>One model, on both model surfaces and in governance.</summary>
/// <remarks>
/// <para>
/// <b>Two surfaces, never interchangeable.</b> The Provider Model Catalogue states what a provider's
/// adapter supports; the Governed AI Model Registry states what Nexus permits for routing. This record
/// carries membership in each as its own member, which is what lets a model be
/// <see cref="AiModelAuthorityClassification.ProviderSupportedNotRegisteredForRouting"/> rather than
/// being silently promoted into routability by a reader that had only one flag to look at.
/// </para>
/// </remarks>
public sealed record AiModelOperationsView
{
    /// <summary>The model identifier, vendor-prefixed.</summary>
    public required string ModelId { get; init; }

    /// <summary>The provider that serves it, where one is declared.</summary>
    public string? ProviderId { get; init; }

    /// <summary>A human-readable name.</summary>
    public string? DisplayName { get; init; }

    /// <summary>The model appears in a provider's own catalogue. Surface A.</summary>
    public required bool ProviderSupported { get; init; }

    /// <summary>The model appears in the governed registry. Surface B.</summary>
    public required bool GovernedRegistered { get; init; }

    /// <summary>Where the two surfaces place this model, as one closed value.</summary>
    public required AiModelAuthorityClassification Classification { get; init; }

    /// <summary>The registry entry's own <c>Enabled</c> flag. False for a model not in the registry.</summary>
    public required bool Enabled { get; init; }

    /// <summary>The registry entry's approval status, by name.</summary>
    public required string Approval { get; init; }

    /// <summary>The registry entry's lifecycle availability, by name.</summary>
    public string? Availability { get; init; }

    /// <summary>
    /// A governed route could reach this model as the registry stands.
    /// </summary>
    /// <remarks>
    /// Configuration-derived, like the provider axis of the same name. False for every model on an
    /// estate whose registry approves nothing, which is this estate's committed state.
    /// </remarks>
    public required bool RoutableByConfiguration { get; init; }

    /// <summary>
    /// The capabilities the governed registry declares for this model.
    /// </summary>
    /// <remarks>
    /// <b>Governed capability identifiers, and only from the registry.</b> The two surfaces use
    /// different vocabularies — the registry speaks the estate's <c>CapabilityId</c> values
    /// (<c>chat.complete</c>, <c>code.review</c>) while a provider's catalogue speaks its own capability
    /// flags (<c>Chat</c>, <c>Vision</c>) — and merging them into one list would produce a field whose
    /// meaning depended on which surface happened to answer. Empty for a model the registry does not
    /// declare; see <see cref="ProviderCapabilities"/> for the other vocabulary.
    /// </remarks>
    public required IReadOnlyList<string> Capabilities { get; init; }

    /// <summary>
    /// The capabilities a provider's own catalogue declares for this model.
    /// </summary>
    /// <remarks>
    /// A different vocabulary from <see cref="Capabilities"/>, deliberately kept apart. These are the
    /// provider adapter's own capability flags, which state what the adapter believes it can serve;
    /// they are not governed capability identifiers and confer no permission.
    /// </remarks>
    public required IReadOnlyList<string> ProviderCapabilities { get; init; }

    /// <summary>
    /// The context window in tokens, where a surface states one.
    /// </summary>
    /// <remarks>
    /// Null where neither surface states it — not zero, which would read as a model that accepts no
    /// context and is therefore unusable for a reason nobody recorded.
    /// </remarks>
    public int? ContextWindow { get; init; }

    /// <summary>
    /// The provider's declared cost per thousand input tokens, as an invariant string.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Vendor catalogue metadata, not a measured cost. See <see cref="AiPricingAuthority"/>.
    /// </para>
    /// <para>
    /// <b>A string, because the digest must be reproducible outside .NET.</b> A JSON number is not one
    /// value across implementations: .NET writes <c>1.0</c> where a JavaScript consumer parses <c>1</c>
    /// and writes it back as <c>1</c>, and the two digests then disagree about a document neither
    /// implementation changed. Carrying rates as invariant strings removes the divergence instead of
    /// documenting it. Format:
    /// <c>decimal.ToString(CultureInfo.InvariantCulture)</c>, or null where no rate is stated — never
    /// <c>"0"</c>, which would assert a free model rather than an unstated price.
    /// </para>
    /// </remarks>
    public string? CatalogueCostPer1kIn { get; init; }

    /// <summary>The provider's declared cost per thousand output tokens, as an invariant string.</summary>
    /// <remarks>See <see cref="CatalogueCostPer1kIn"/> for why this is a string.</remarks>
    public string? CatalogueCostPer1kOut { get; init; }
}

/// <summary>
/// Where a model sits across the two model surfaces.
/// </summary>
/// <remarks>
/// <b>Closed, and exhaustive over the two booleans it summarises.</b> Every combination a consumer can
/// meet is named, so a reader never has to interpret a pair of flags itself. It is a <em>summary</em> of
/// the flags on the record, never a replacement for them: a consumer that wants to know one surface's
/// answer reads that surface's member.
/// </remarks>
[System.Text.Json.Serialization.JsonConverter(
    typeof(System.Text.Json.Serialization.JsonStringEnumConverter<AiModelAuthorityClassification>))]
public enum AiModelAuthorityClassification
{
    /// <summary>No surface declares it. Not representable in a well-formed document.</summary>
    Undeclared = 0,

    /// <summary>
    /// The provider's adapter supports it; the governed registry does not permit it.
    /// </summary>
    /// <remarks>
    /// <b>The W10.7A decision, as a value.</b> <c>openai:gpt-4o</c> sits here and stays here until an
    /// operator records a governed registration for it. A consumer must never read this as routable,
    /// and must never "fix" it by copying the catalogue entry into the registry — that copy is the act
    /// the decision reserves to an operator.
    /// </remarks>
    ProviderSupportedNotRegisteredForRouting = 1,

    /// <summary>The governed registry declares it, and governance currently permits a route to it.</summary>
    GovernedRoutable = 2,

    /// <summary>
    /// The governed registry declares it, but governance does not currently permit a route.
    /// </summary>
    /// <remarks>
    /// The state of a registered model that is disabled, unapproved, or whose provider is not enabled.
    /// Still not routable — the distinction from <see cref="GovernedRoutable"/> is that this model has
    /// an operator-authored registry entry that could be activated, whereas a
    /// <see cref="ProviderSupportedNotRegisteredForRouting"/> model has none.
    /// </remarks>
    GovernedRegisteredNotRoutable = 3,
}

/// <summary>The two model surfaces stated as counts, beside the rows that are their authority.</summary>
public sealed record AiModelAuthoritySummary
{
    /// <summary>Models a provider's own catalogue declares. Surface A.</summary>
    public required int ProviderSupportedModels { get; init; }

    /// <summary>Models the governed registry declares. Surface B.</summary>
    public required int GovernedRegisteredModels { get; init; }

    /// <summary>Models a governed route could reach as configuration stands.</summary>
    public required int RoutableModels { get; init; }

    /// <summary>
    /// Models a provider supports that the governed registry does not declare.
    /// </summary>
    /// <remarks>
    /// Never derived by subtraction on a consumer's side. A count a consumer computes and a count the
    /// producer states are two numbers that will eventually disagree, and this is the number W10.7A's
    /// decision is about, so it is stated rather than left to be inferred.
    /// </remarks>
    public required int ProviderSupportedOnlyModels { get; init; }
}

/// <summary>What routing is configured to do, and what it has been observed to do.</summary>
/// <remarks>
/// <para>
/// <b>Configuration and observation are separate members and are never summed.</b> The directive is
/// explicit that a configured fallback must not be presented as active failover without execution
/// evidence. <see cref="ConfiguredFallbackDepth"/> is what an operator wrote;
/// <see cref="ObservedFallbacks"/> is what executions did, and it is empty on an estate that has run
/// none. A consumer rendering failover must read the second, not the first.
/// </para>
/// </remarks>
public sealed record AiRoutingInventory
{
    /// <summary>The configured ranking objective, by name.</summary>
    public required string Objective { get; init; }

    /// <summary>How many routes beyond the primary a failover may walk, as configured.</summary>
    public required int ConfiguredFallbackDepth { get; init; }

    /// <summary>
    /// The routes configuration declares, as eligibility rather than as evidence.
    /// </summary>
    /// <remarks>
    /// One row per registered model, carrying whether the governed gates would permit it. A row saying
    /// "eligible" is a statement about configuration; it is not a statement that anything ran.
    /// </remarks>
    public required IReadOnlyList<AiConfiguredRoute> ConfiguredRoutes { get; init; }

    /// <summary>
    /// Failover that an execution has actually performed.
    /// </summary>
    /// <remarks>
    /// <b>Empty is the honest answer here and not a defect.</b> The estate's operational ledger is
    /// in-process; a publication from a freshly composed Head has observed no executions, so it has
    /// observed no fallbacks. Reporting the configured depth in this field would be the exact
    /// substitution the directive forbids.
    /// </remarks>
    public required AiObservedFailover ObservedFailover { get; init; }

    /// <summary>Capabilities the registry's models declare they can serve.</summary>
    /// <remarks>
    /// The capability routing surface: which capabilities have a candidate at all. A capability with no
    /// candidate is a capability the estate cannot serve, which is a different finding from one whose
    /// candidates are all gated.
    /// </remarks>
    public required IReadOnlyList<AiCapabilityRoute> CapabilityRoutes { get; init; }
}

/// <summary>One route as configuration declares it.</summary>
public sealed record AiConfiguredRoute
{
    /// <summary>The model identifier.</summary>
    public required string ModelId { get; init; }

    /// <summary>The provider identifier.</summary>
    public required string ProviderId { get; init; }

    /// <summary>Whether the governed gates would permit this route as configuration stands.</summary>
    public required bool Eligible { get; init; }

    /// <summary>Why it is not eligible, by name, where it is not.</summary>
    public string? IneligibilityReason { get; init; }
}

/// <summary>What executions have been observed to do, as opposed to what is configured.</summary>
public sealed record AiObservedFailover
{
    /// <summary>Whether any execution has been observed at all.</summary>
    public required bool ExecutionsObserved { get; init; }

    /// <summary>Executions the estate has recorded.</summary>
    public required int Executions { get; init; }

    /// <summary>Recorded attempts that ran as a fallback rather than the primary route.</summary>
    public required int FallbackAttempts { get; init; }

    /// <summary>Where the observation came from, by name.</summary>
    public required string ObservationSource { get; init; }
}

/// <summary>One capability and its candidate routes.</summary>
public sealed record AiCapabilityRoute
{
    /// <summary>The capability identifier.</summary>
    public required string Capability { get; init; }

    /// <summary>The models declaring it, ordered by identifier, ordinally.</summary>
    public required IReadOnlyList<string> CandidateModelIds { get; init; }

    /// <summary>How many of those candidates the governed gates would permit.</summary>
    public required int EligibleCandidates { get; init; }
}

/// <summary>The runtime units the estate composes, each on four independent axes.</summary>
/// <remarks>
/// <para>
/// <b>Implemented, registered, configured-enabled and hosted are four questions, and this estate
/// answers them differently for different units.</b> The health probe background service is
/// implemented and would be registered — but it is not registered, because the guard that composes it
/// reads a configuration member that is false. A consumer that equated "the class exists" with "the
/// sweep runs" would report a running probe on an estate that has none, which is the exact reading the
/// directive forbids.
/// </para>
/// </remarks>
public sealed record AiRuntimeInventory
{
    /// <summary>The executable host, if the composed estate has one.</summary>
    public required AiRuntimeUnit Host { get; init; }

    /// <summary>Every runtime unit the AI Head owns, ordered by identifier, ordinally.</summary>
    public required IReadOnlyList<AiRuntimeUnit> Units { get; init; }

    /// <summary>
    /// Whether this publication can state that anything is <em>running</em>.
    /// </summary>
    /// <remarks>
    /// <b>False, and it is a statement about the observation rather than about the estate.</b> A
    /// publisher composed inside its own process can report what that process composed. It cannot
    /// truthfully report that a host elsewhere is running, and this estate forbids process-table
    /// liveness checks as evidence. A consumer must therefore render <c>running</c> as unknown on this
    /// document rather than inferring it from anything else here.
    /// </remarks>
    public required bool RunningStateObserved { get; init; }

    /// <summary>Why running state is or is not observable. Always populated.</summary>
    public required string RunningStateReason { get; init; }

    /// <summary>The APIs the host maps, by route prefix and method.</summary>
    public required IReadOnlyList<AiApiSurface> Apis { get; init; }
}

/// <summary>An API surface the host declares.</summary>
public sealed record AiApiSurface
{
    /// <summary>The route prefix.</summary>
    public required string Prefix { get; init; }

    /// <summary>What the surface is for, by name.</summary>
    public required string Kind { get; init; }

    /// <summary>Whether the surface is mapped by the host's route table.</summary>
    public required bool Mapped { get; init; }
}

/// <summary>
/// One runtime unit, on its four independent axes.
/// </summary>
/// <remarks>
/// A unit is a component with a lifetime — a hosted service, a scheduler, a router, a gateway, a tool
/// registry, an in-process store. The axes below are the questions an operator actually asks, and none
/// of them implies another.
/// </remarks>
public sealed record AiRuntimeUnit
{
    /// <summary>The unit's stable identifier.</summary>
    public required string UnitId { get; init; }

    /// <summary>The unit's kind, by name: Host, BackgroundService, Router, Gateway, Store, Registry.</summary>
    public required string Kind { get; init; }

    /// <summary>An implementation type exists.</summary>
    public required bool Implemented { get; init; }

    /// <summary>The composition root registers it in the container.</summary>
    public required bool RegisteredInContainer { get; init; }

    /// <summary>Configuration says it is switched on. Null where the unit has no such switch.</summary>
    public bool? ConfiguredEnabled { get; init; }

    /// <summary>The host would run it under its own lifetime.</summary>
    public required bool Hosted { get; init; }

    /// <summary>
    /// Whether this unit spawns a repeating schedule.
    /// </summary>
    /// <remarks>
    /// Distinct from <see cref="Hosted"/>: a hosted unit can run once at startup, and a scheduler that
    /// is not hosted cannot run at all.
    /// </remarks>
    public required bool Scheduled { get; init; }
}

/// <summary>The health plane: what is measured, what is declared, and what is not observed.</summary>
/// <remarks>
/// <para>
/// <b>Four facts the directive requires kept apart, and they are four members here.</b> Host liveness,
/// AI runtime health, provider health and model health are independent questions. On this estate only
/// the first has an implementation at all — and it is a hardcoded literal, which the document states
/// rather than hiding behind a green word.
/// </para>
/// </remarks>
public sealed record AiHealthAuthority
{
    /// <summary>What the host's <c>/health</c> route observes, by name.</summary>
    /// <remarks>
    /// <see cref="AiHostLivenessBasis.Literal"/> means the route returns a constant and observes
    /// nothing — not the process, not the runtime, not a dependency. An operator reading a green
    /// liveness probe must be able to tell that from a probe that actually checked something.
    /// </remarks>
    public required AiHostLivenessBasis HostLiveness { get; init; }

    /// <summary>Whether host liveness is a statement about the AI runtime rather than the process.</summary>
    public required bool HostLivenessImpliesRuntimeHealth { get; init; }

    /// <summary>Whether a health probe implementation exists in the estate at all.</summary>
    public required bool ProbeImplemented { get; init; }

    /// <summary>Whether configuration composes the probe sweep.</summary>
    public required bool ProbeConfiguredEnabled { get; init; }

    /// <summary>Whether the sweep is registered as a hosted background service.</summary>
    public required bool ProbeHosted { get; init; }

    /// <summary>The configured sweep interval in seconds, where one is configured.</summary>
    public int? ProbeIntervalSeconds { get; init; }

    /// <summary>Whether a probe implementation is registered that can reach a provider.</summary>
    public required bool ProbeCanReachProvider { get; init; }

    /// <summary>The snapshot's own source marker, as the health plane reports it.</summary>
    public required string SnapshotSource { get; init; }

    /// <summary>
    /// When the snapshot was taken, ISO-8601 round-trip form — or null when it was not taken by anything.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Null is the honest value for a declared snapshot, and publishing an instant there is a defect
    /// rather than a detail.</b> The estate's health plane has two kinds of snapshot. A probe produces
    /// one, and its instant is authority data — a real observation with a real time, which belongs
    /// inside the semantic digest. Configuration produces the other: the composition root rebuilds the
    /// declared snapshot on every start, so its instant is when <em>this process</em> happened to read
    /// the file and says nothing about the estate.
    /// </para>
    /// <para>
    /// <b>Which is why this member was found by republishing, not by reading.</b> A volatile instant
    /// inside the payload made the digest change on every publish of unchanged facts — defeating
    /// idempotency entirely, and making the digest unable to answer the one question it exists for. It
    /// survived the whole test suite because every test published twice from a single composition with a
    /// fixed clock; the divergence needs a second process to appear.
    /// </para>
    /// <para>
    /// <see cref="SnapshotSource"/> still names the source, so a consumer told null here can tell a
    /// declared snapshot from an observed one and knows why there is no instant.
    /// </para>
    /// </remarks>
    public string? SnapshotTakenAt { get; init; }

    /// <summary>The provider rows the snapshot carries.</summary>
    public required IReadOnlyList<AiHealthAxisRow> ProviderRows { get; init; }

    /// <summary>The model rows the snapshot carries.</summary>
    public required IReadOnlyList<AiHealthAxisRow> ModelRows { get; init; }

    /// <summary>
    /// Whether provider health is genuinely observed rather than declared.
    /// </summary>
    /// <remarks>
    /// <b>False on this estate, and the gap identifier is carried beside it.</b> A declared snapshot is
    /// an operator's assertion about the world; it is not an observation of it, and no member of this
    /// document conflates the two.
    /// </remarks>
    public required bool ProviderHealthObserved { get; init; }

    /// <summary>Whether model health is genuinely observed rather than declared.</summary>
    public required bool ModelHealthObserved { get; init; }

    /// <summary>The source gap covering any of the above that is not observed.</summary>
    public string? GapId { get; init; }
}

/// <summary>What a host liveness route is actually based on.</summary>
[System.Text.Json.Serialization.JsonConverter(
    typeof(System.Text.Json.Serialization.JsonStringEnumConverter<AiHostLivenessBasis>))]
public enum AiHostLivenessBasis
{
    /// <summary>The route is not mapped.</summary>
    Absent = 0,

    /// <summary>The route returns a constant. It observes nothing.</summary>
    Literal = 1,

    /// <summary>The route observes the process.</summary>
    Process = 2,

    /// <summary>The route observes the AI runtime's own dependencies.</summary>
    Runtime = 3,
}

/// <summary>One health row, with the axis it belongs to stated rather than implied by position.</summary>
public sealed record AiHealthAxisRow
{
    /// <summary>The provider this row is about.</summary>
    public required string ProviderId { get; init; }

    /// <summary>The model this row is about, or null for the provider as a whole.</summary>
    public string? ModelId { get; init; }

    /// <summary>The state, by name.</summary>
    public required string State { get; init; }

    /// <summary>
    /// Whether this row's state was measured rather than declared.
    /// </summary>
    /// <remarks>
    /// The member that makes a declared <c>Unknown</c> distinguishable from a measured one. Both are
    /// <c>Unknown</c> as a state; only one of them is evidence.
    /// </remarks>
    public required bool Observed { get; init; }
}

/// <summary>Whether a telemetry axis exists, and why not where it does not.</summary>
/// <remarks>
/// <para>
/// <b>Its own type, and deliberately not a number.</b> The directive forbids rendering
/// <c>0 requests</c>, <c>0 tokens</c> or <c>$0</c> for unavailable telemetry, and the structural way to
/// obey that is to have no numeric member for a consumer to render. An unavailable axis carries a
/// reason and a gap identifier instead.
/// </para>
/// <para>
/// <b>Availability and durability are separate.</b> An in-process ledger is a real record of what
/// happened and it is not durable; collapsing the two would either deny the estate the telemetry it
/// does have or overstate what survives a restart.
/// </para>
/// </remarks>
public sealed record AiTelemetryAvailability
{
    /// <summary>Which axis this is. <c>usage</c> or <c>cost</c>.</summary>
    public required string Axis { get; init; }

    /// <summary>The availability, as a closed value.</summary>
    public required AiTelemetryState State { get; init; }

    /// <summary>Whether what exists survives the process that recorded it.</summary>
    public required bool Durable { get; init; }

    /// <summary>The store, by name, where one exists.</summary>
    public string? Store { get; init; }

    /// <summary>Where the telemetry is scoped, by name, where one exists.</summary>
    public string? Scope { get; init; }

    /// <summary>
    /// How many records the store held when this document was produced.
    /// </summary>
    /// <remarks>
    /// <b>Present because it is measured, and it is a count of records rather than a total of the thing
    /// measured.</b> Zero records is a fact about a freshly composed process; it is not a claim that no
    /// tokens were consumed. A consumer must not render this as a spend or consumption figure.
    /// </remarks>
    public required int RecordsHeld { get; init; }

    /// <summary>Why telemetry is in this state. Always populated.</summary>
    public required string Reason { get; init; }

    /// <summary>The source gap covering this axis, where one applies.</summary>
    public string? GapId { get; init; }
}

/// <summary>How available a telemetry axis is.</summary>
[System.Text.Json.Serialization.JsonConverter(
    typeof(System.Text.Json.Serialization.JsonStringEnumConverter<AiTelemetryState>))]
public enum AiTelemetryState
{
    /// <summary>No store exists on this estate.</summary>
    Unavailable = 0,

    /// <summary>A store exists and is not durable, so it is empty outside the process that wrote it.</summary>
    InProcessOnly = 1,

    /// <summary>A durable store exists.</summary>
    Available = 2,
}

/// <summary>
/// The pricing metadata the estate holds.
/// </summary>
/// <remarks>
/// <para>
/// <b>Pricing is not cost and this type exists to say so.</b> A rate per thousand tokens transcribed
/// from a vendor's price list is a statement about the world; a cost is a statement about what this
/// estate spent. The estate holds the first and does not hold the second, and a consumer that rendered
/// the first as the second would report spend nobody measured.
/// </para>
/// </remarks>
public sealed record AiPricingAuthority
{
    /// <summary>The pricing source, by name.</summary>
    public required string Source { get; init; }

    /// <summary>Whether a rate is stated for any model.</summary>
    public required bool RatesConfigured { get; init; }

    /// <summary>How many registered models carry a stated rate.</summary>
    public required int RatedModels { get; init; }

    /// <summary>The currencies the stated rates are denominated in.</summary>
    public required IReadOnlyList<string> Currencies { get; init; }

    /// <summary>The posture for an execution the estate cannot price, by name.</summary>
    public required string OnUnpricedExecution { get; init; }
}

/// <summary>
/// One source gap, by identifier.
/// </summary>
/// <remarks>
/// A gap is carried rather than merely reported because a consumer rendering an unavailable fact must
/// be able to say why it is unavailable, and it must not have to hold a second artefact — a report, a
/// wiki page — that can drift from the document it explains.
/// </remarks>
public sealed record AiSourceGap
{
    /// <summary>The gap's stable identifier, as the programme records it.</summary>
    public required string GapId { get; init; }

    /// <summary>What is missing, in one sentence.</summary>
    public required string Summary { get; init; }

    /// <summary>Who owns closing it.</summary>
    public required string Owner { get; init; }
}
