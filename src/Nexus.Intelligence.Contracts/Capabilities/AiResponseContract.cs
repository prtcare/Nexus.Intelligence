namespace Nexus.Intelligence.Contracts;

/// <summary>The shape of answer the caller requires.</summary>
/// <remarks>
/// Requirement, not preference. A caller that needs a JSON object it can deserialise is not helped by
/// a fluent paragraph, so when the shape cannot be produced the execution fails rather than
/// substituting prose. The existing <see cref="ReplyFormat"/> (<c>PlainText</c> | <c>Markdown</c>) is
/// a <em>rendering</em> choice and remains in use for the reply body; this type states the
/// <em>contract</em> the body must satisfy.
/// </remarks>
public sealed record AiResponseContract
{
    /// <summary>The required output shape.</summary>
    public AiResponseKind Kind { get; init; } = AiResponseKind.Text;

    /// <summary>
    /// A JSON Schema the structured output must validate against. Required when
    /// <see cref="Kind"/> is <see cref="AiResponseKind.Structured"/>.
    /// </summary>
    /// <remarks>
    /// Supplied by the caller because only the caller knows the shape it can consume. It is a schema,
    /// not a prompt fragment, and it must be treated as data: it is validated before use and never
    /// concatenated into an instruction without escaping.
    /// </remarks>
    public string? OutputSchemaJson { get; init; }

    /// <summary>Schema identity, for the audit record. Absent when the output is unstructured.</summary>
    public string? OutputSchemaId { get; init; }

    /// <summary>A ceiling on generated output. The AI Head may impose a lower one.</summary>
    public int? MaxOutputTokens { get; init; }

    /// <summary>Unstructured prose. The default.</summary>
    public static AiResponseContract Text { get; } = new();

    /// <summary>Structured output validated against <paramref name="schemaJson"/>.</summary>
    public static AiResponseContract Structured(string schemaId, string schemaJson) => new()
    {
        Kind = AiResponseKind.Structured,
        OutputSchemaId = schemaId,
        OutputSchemaJson = schemaJson,
    };
}

/// <summary>The required shape of an AI response body.</summary>
public enum AiResponseKind
{
    /// <summary>Free text, possibly Markdown.</summary>
    Text = 0,

    /// <summary>A JSON document matching a caller-supplied schema.</summary>
    Structured = 1,

    /// <summary>Both a human-readable rendering and a structured document.</summary>
    TextAndStructured = 2,

    /// <summary>An embedding vector. Used by <c>embedding.generate</c>.</summary>
    Embedding = 3,

    /// <summary>Binary or referenced image content. Used by <c>image.generate</c>.</summary>
    Image = 4,
}
