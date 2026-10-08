using System.Text.Json;
using System.Text.Json.Serialization;

namespace Nexus.Intelligence.Contracts;

/// <summary>
/// Reads and writes a <see cref="CapabilityId"/> as a plain JSON string.
/// </summary>
/// <remarks>
/// <para>
/// <b>This converter is not a convenience; without it the gateway cannot read its own request body.</b>
/// <see cref="CapabilityId"/> holds a private constructor by design — the only way to obtain one is
/// <see cref="CapabilityId.TryParse"/>, so an unvalidated identifier cannot exist. That is the right
/// design for the type and the wrong shape for a serialiser: System.Text.Json requires a parameterless,
/// a singular parameterised, or a <c>[JsonConstructor]</c>-annotated constructor, and a private one is
/// none of those. The default converter therefore refuses to read the type at all, and the gateway's
/// invoke route — which binds <see cref="AiCapabilityRequest"/> straight from the body — answered
/// <c>400</c> to every caller composed of a valid contract. Nothing caught it because every test built
/// a request as an object and never put one on the wire.
/// </para>
/// <para>
/// <b>It is applied by attribute rather than by registration.</b> A consumer that had to remember to
/// add this to its <see cref="JsonSerializerOptions"/> is a consumer that will one day not remember,
/// and the failure would appear as an unexplained rejection at the other end of the boundary. Three
/// repositories read these contracts; the attribute means all of them get the correct shape without
/// being told about it. This follows the same rule the audit record's serialisation states for itself:
/// if the safe path is a different, longer path, the unsafe one is what will be used.
/// </para>
/// <para>
/// <b>A malformed identifier is refused, never defaulted.</b> A bad capability identifier on the wire
/// is a caller defect, and silently substituting anything — a default capability, a skipped member —
/// would execute the wrong work under the right name. The <see cref="JsonException"/> carries
/// <see cref="CapabilityId.TryParse"/>'s own reason, so the caller is told which rule it broke rather
/// than merely that something was wrong.
/// </para>
/// <para>
/// <b>The wire shape is a string, and that is a decision.</b> The previous shape was an object —
/// <c>{"value":"code.review"}</c> — because that is what the default converter writes for a record
/// with one public property. It was never a deliberate contract. Moving to a plain string is safe
/// precisely because the object form was unreadable by anything, including this Head, so no working
/// consumer can be depending on it. The string form is also the one the type documents for itself:
/// "It is a validated <b>string</b>".
/// </para>
/// </remarks>
public sealed class CapabilityIdJsonConverter : JsonConverter<CapabilityId>
{
    /// <summary>Reads a capability identifier, or fails with the parse rule the caller broke.</summary>
    public override CapabilityId Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException(
                $"A capability identifier must be a JSON string; found {reader.TokenType}.");
        }

        var candidate = reader.GetString();

        if (!CapabilityId.TryParse(candidate, out var parsed, out var reason))
        {
            throw new JsonException(reason);
        }

        return parsed!;
    }

    /// <summary>Writes a capability identifier as its canonical string form.</summary>
    public override void Write(
        Utf8JsonWriter writer,
        CapabilityId value,
        JsonSerializerOptions options)
    {
        ArgumentNullException.ThrowIfNull(writer);
        ArgumentNullException.ThrowIfNull(value);

        // The canonical Value, not the raw text some caller once sent. A round trip through this
        // converter cannot change an identifier, because TryParse refuses anything that is not already
        // canonical - so what is written here is what a reader will parse back, unchanged.
        writer.WriteStringValue(value.Value);
    }
}
