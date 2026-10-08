using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The one serialiser configuration a published AI operations document is written with.
/// </summary>
/// <remarks>
/// <para>
/// <b>It is shared rather than repeated at each call site, because a writer and a digester that
/// disagreed about encoding would produce a document whose digest did not describe it.</b>
/// </para>
/// <para>
/// <b><see cref="JavaScriptEncoder.UnsafeRelaxedJsonEscaping"/> on purpose, and the name is about HTML
/// rather than about JSON.</b> The default encoder escapes <c>&amp;</c>, <c>&lt;</c>, <c>&gt;</c> and
/// <c>+</c> as <c>\u00XX</c>. That is the right default for a payload that might be interpolated into
/// markup, and it is the wrong one here: this document is written to a file and read back as JSON, and
/// an independent consumer's own serialiser would not escape those characters. Two encodings of one
/// payload are two digests, and the disagreement would look exactly like a changed document. Nothing
/// here is ever placed in an HTML context.
/// </para>
/// </remarks>
public static class AiOperationsJson
{
    /// <summary>Compact and canonical. The digest covers exactly these bytes.</summary>
    public static readonly JsonSerializerOptions Canonical = new()
    {
        WriteIndented = false,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.Never,
    };

    /// <summary>Indented for a human reader. The digest does not cover these bytes.</summary>
    /// <remarks>
    /// The published file is readable because an operator will open it. The digest is computed over the
    /// compact form so that re-indenting the file, or a consumer implementing a different pretty-printer,
    /// does not change what the document <em>is</em>.
    /// </remarks>
    public static readonly JsonSerializerOptions Published = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.Never,
    };
}

/// <summary>
/// The digest that gives a published AI operations document its semantic identity.
/// </summary>
/// <remarks>
/// <para>
/// <b>It is computed over the payload's canonical JSON and nothing else.</b> Not the file, not the
/// envelope, not the timestamp. Two publications of the same operational facts are the same document
/// however many times the publisher ran, and this is the member that makes that checkable by a consumer
/// that never sees the producer.
/// </para>
/// <para>
/// <b>The algorithm is stated here rather than left to the producer.</b> A digest whose algorithm lives
/// only in its producer is a digest no independent implementation can verify, and a consumer that
/// computed a different value from the same payload would be unable to tell whether the document had
/// changed or its own code was wrong. Both sides read this type.
/// </para>
/// <para>
/// <b>Canonical JSON, not "the JSON we happened to write".</b> <see cref="Canonicalize"/> is the one
/// definition of the bytes the digest covers:
/// </para>
/// <list type="number">
/// <item><description>object members sorted by key, ordinal, recursively;</description></item>
/// <item><description>no insignificant whitespace — the separators are <c>,</c> and <c>:</c>;</description></item>
/// <item><description>scalars in their invariant, round-trippable form.</description></item>
/// </list>
/// <para>
/// <b>Why sorted keys rather than the producer's declaration order.</b> The estate's existing publishers
/// digest a payload serialised through its declared type, which is deterministic in .NET but is not
/// reproducible by a consumer written in another language: reproducing it means reproducing the
/// producer's property declaration order, and nothing in the wire document states what that order is.
/// Sorting is a rule both implementations can execute from the document alone. The digest properties
/// are unchanged — SHA-256, over the payload only, clock excluded — only the byte rule is stated more
/// portably.
/// </para>
/// <para>
/// <b>Scalars choose their wire types so that the rule is executable outside .NET.</b> Instants and
/// money are invariant strings and counts are integers, because a JSON number is not one value across
/// implementations: <c>1.0</c> in .NET is <c>1</c> after a JavaScript round trip. This is a property of
/// the contract's member types, not of this algorithm — see
/// <see cref="AiModelOperationsView.CatalogueCostPer1kIn"/>.
/// </para>
/// </remarks>
public static class AiOperationsDigest
{
    /// <summary>The algorithm's name, carried in every error and every report that mentions it.</summary>
    public const string Algorithm = "SHA-256";

    /// <summary>The prefix every digest carries, so a digest is never mistaken for a raw value.</summary>
    public const string Prefix = "sha256:";

    /// <summary>
    /// The length of a complete digest: <see cref="Prefix"/> plus 64 lower-case hex characters.
    /// </summary>
    /// <remarks>
    /// Stated once, because a producer and a consumer both validate it and a consumer's own regex is a
    /// second definition of the same rule. The estate's existing Atlas loader hard-codes the same
    /// expression; this member exists so the AI Head does not add a third.
    /// </remarks>
    public const int PrefixedLength = 7 + 64;

    /// <summary>Computes the digest of a canonical JSON payload.</summary>
    /// <param name="canonicalJson">
    /// The payload's canonical JSON. Must already be canonical — see <see cref="Canonicalize"/>.
    /// </param>
    /// <returns>The digest, lower-case hexadecimal, prefixed with <see cref="Prefix"/>.</returns>
    /// <remarks>
    /// This method does not canonicalize its input; it digests exactly the bytes it is given. That is
    /// deliberate: a producer that canonicalized here would hide the fact that its serializer was not
    /// deterministic, and the entire value of the digest is that it is a function of the bytes that
    /// were actually written.
    /// </remarks>
    public static string OfCanonicalJson(string canonicalJson)
    {
        ArgumentNullException.ThrowIfNull(canonicalJson);

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(canonicalJson));

        return Prefix + Convert.ToHexStringLower(hash);
    }

    /// <summary>
    /// Verifies a digest against a canonical JSON payload, in constant time relative to the digests.
    /// </summary>
    /// <remarks>
    /// A comparison rather than an accessor, because the only thing a consumer does with a digest is
    /// compare it, and giving that its own method is what keeps a consumer from open-coding a string
    /// equality that ignores case or trims.
    /// </remarks>
    public static bool Verifies(string canonicalJson, string digest)
    {
        ArgumentNullException.ThrowIfNull(canonicalJson);

        if (string.IsNullOrWhiteSpace(digest))
        {
            return false;
        }

        var computed = OfCanonicalJson(canonicalJson);

        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(computed),
            Encoding.UTF8.GetBytes(digest.Trim()));
    }

    /// <summary>
    /// Computes the digest of a payload, canonicalising it first.
    /// </summary>
    /// <remarks>
    /// The producer's entry point. A consumer verifying a document parses the payload it was given and
    /// passes the same node here, so both sides run one implementation of one rule.
    /// </remarks>
    public static string Of(AiOperationsReadModelPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload);

        return OfCanonicalJson(Canonicalize(ToNode(payload)));
    }

    /// <summary>Verifies a document's stated digest against its payload.</summary>
    /// <remarks>
    /// The consumer's entry point, and the reason the digest is worth carrying: a consumer that can only
    /// compare one digest to another digest has to trust the producer for both. This compares the
    /// stated value against the payload it was actually given.
    /// </remarks>
    public static bool VerifiesPayload(AiOperationsReadModelPayload payload, string digest)
    {
        ArgumentNullException.ThrowIfNull(payload);

        return Verifies(Canonicalize(ToNode(payload)), digest);
    }

    /// <summary>Converts a payload to the JSON node tree the canonicaliser walks.</summary>
    private static System.Text.Json.Nodes.JsonNode ToNode(AiOperationsReadModelPayload payload)
        => JsonSerializer.SerializeToNode(payload, AiOperationsJson.Canonical)
            ?? throw new InvalidOperationException(
                "The payload serialised to JSON null. A payload that cannot be represented is a defect "
                + "in the contract, not a document without content.");

    /// <summary>
    /// Rewrites JSON into the canonical form the digest covers.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Sorted keys, ordinal, recursively.</b> Object member order in JSON is semantically
    /// insignificant, so a digest that depended on it would report two identical documents as
    /// different whenever a serializer reordered a dictionary.
    /// </para>
    /// <para>
    /// <b>Culture-invariant numbers.</b> A decimal written under a comma-decimal culture would produce
    /// a digest no other culture could reproduce, which on a build farm means two hosts disagreeing
    /// about whether a document changed.
    /// </para>
    /// <para>
    /// This operates on <see cref="System.Text.Json.Nodes.JsonNode"/> so it has no opinion about the
    /// source document's formatting, and it is the only place in the estate that defines what
    /// "canonical" means for a published AI operations document.
    /// </para>
    /// </remarks>
    public static string Canonicalize(System.Text.Json.Nodes.JsonNode? node)
    {
        var builder = new StringBuilder();
        Write(node, builder);
        return builder.ToString();
    }

    private static void Write(System.Text.Json.Nodes.JsonNode? node, StringBuilder builder)
    {
        switch (node)
        {
            case null:
                builder.Append("null");
                return;

            case System.Text.Json.Nodes.JsonObject obj:
                builder.Append('{');

                var first = true;

                // Ordinal, so the ordering does not depend on the current culture's collation. A
                // culture-sensitive sort would place the same keys in different orders on different
                // hosts and change the digest of an unchanged document.
                foreach (var property in obj.OrderBy(pair => pair.Key, StringComparer.Ordinal))
                {
                    if (!first)
                    {
                        builder.Append(',');
                    }

                    first = false;
                    WriteString(property.Key, builder);
                    builder.Append(':');
                    Write(property.Value, builder);
                }

                builder.Append('}');
                return;

            case System.Text.Json.Nodes.JsonArray array:
                builder.Append('[');

                for (var index = 0; index < array.Count; index++)
                {
                    if (index > 0)
                    {
                        builder.Append(',');
                    }

                    Write(array[index], builder);
                }

                builder.Append(']');
                return;

            default:
                // A scalar. JsonNode's own ToJsonString is already canonical for scalars: it is
                // culture-invariant and emits no insignificant whitespace. It is passed the same
                // options the rest of the document is written with, so a scalar is escaped exactly
                // once and by one encoder.
                builder.Append(node.ToJsonString(AiOperationsJson.Canonical));
                return;
        }
    }

    private static void WriteString(string value, StringBuilder builder)
        => builder.Append(JsonSerializer.Serialize(value, AiOperationsJson.Canonical));
}
