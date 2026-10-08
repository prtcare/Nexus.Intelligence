using System.Text.Json;
using System.Text.Json.Serialization;

namespace Nexus.Intelligence.Api;

/// <summary>
/// The JSON configuration the API binds request bodies and writes responses with.
/// </summary>
/// <remarks>
/// <para>
/// <b>This exists so that the server and the tests that prove the server works cannot configure JSON
/// differently.</b> That divergence is not hypothetical: a test that round-trips a contract with its
/// own <see cref="JsonSerializerOptions"/> proves a fact about the test, and the gateway shipped a
/// contract that System.Text.Json could not read while every in-memory test passed. The configuration
/// lives in one place and both callers reach it, so "the tests use what the server uses" is a
/// structural property rather than a promise in a comment.
/// </para>
/// <para>
/// <b>The enum converter is load-bearing.</b> Without it, enums bind as integers, every request that
/// carries one fails model binding, and the caller receives an empty <c>400</c> with no explanation.
/// This is a known, already-diagnosed failure mode on both sides of the boundary — the Experience
/// client carries the same converter for the same reason — so it is stated here rather than
/// rediscovered.
/// </para>
/// </remarks>
public static class AiJsonConfiguration
{
    /// <summary>Applies the AI Head's JSON rules to a serializer configuration.</summary>
    public static void Apply(JsonSerializerOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        options.Converters.Add(new JsonStringEnumConverter());
    }
}
