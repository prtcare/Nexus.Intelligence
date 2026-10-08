using System.Text.RegularExpressions;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

/// <summary>
/// Resolves the sources an answer cites, from the markers the prompt assembler embeds.
/// </summary>
/// <remarks>
/// <para>
/// <b>Extracted in W7F because a second caller appeared, not because a first one was untidy.</b> The
/// citation derivation lived inside <see cref="ResponseComposer"/>, where it was correct and
/// unreachable: only the turn envelope could obtain it, because the composer's answer is a turn
/// response. The capability gateway needs the same fact for the same reason — a caller that receives
/// an answer containing <c>[ctx:doc-7]</c> and a citation list that does not name <c>doc-7</c> has
/// been told something false, and "no sources cited" is a claim rather than a silence.
/// </para>
/// <para>
/// <b>The alternative was duplication, and it was rejected on the evidence.</b> A second copy of the
/// pattern would be a second definition of what a citation marker looks like, and the two would agree
/// until the first time one of them was changed — at which point the turn path and the capability
/// path would report different citation lists for identical model output, with nothing to say which
/// was right. One definition, two callers.
/// </para>
/// <para>
/// <b>A marker that names nothing admitted is dropped.</b> The model is free to write
/// <c>[ctx:anything]</c>, and a citation list built from the model's own text would let it cite a
/// source that was never sent to it — which is a fabricated attribution dressed as a reference. The
/// admitted context is the only thing either caller will resolve against.
/// </para>
/// </remarks>
public static partial class CitationExtractor
{
    /// <summary>
    /// The citations in <paramref name="content"/>, restricted to the admitted context.
    /// </summary>
    /// <param name="content">The model's output. Null is treated as empty, which cites nothing.</param>
    /// <param name="admittedContextIds">
    /// The identifiers of the context items that were actually sent. A marker naming anything else is
    /// dropped rather than reported.
    /// </param>
    /// <remarks>
    /// Ordered by first appearance in the output rather than sorted, because a citation list is read
    /// alongside the answer it belongs to and reordering it would separate the two. Duplicates are
    /// dropped: a model that cites one document three times cited one document.
    /// </remarks>
    public static IReadOnlyList<Citation> Extract(string? content, IReadOnlySet<string> admittedContextIds)
    {
        ArgumentNullException.ThrowIfNull(admittedContextIds);

        if (string.IsNullOrEmpty(content))
        {
            return [];
        }

        return
        [
            .. CitationPattern().Matches(content)
                .Select(match => match.Groups["id"].Value)
                .Distinct(StringComparer.Ordinal)
                .Where(admittedContextIds.Contains)
                .Select(id => new Citation(id, null)),
        ];
    }

    /// <summary>
    /// Mirrors the <c>[ctx:&lt;id&gt;]</c> marker <c>PromptAssembler</c> embeds, which the model echoes
    /// back to cite a source.
    /// </summary>
    /// <remarks>
    /// The pattern is the assembler's contract with the model, so it is stated once here and read by
    /// both callers. Changing the marker in the assembler and not here would silently stop resolving
    /// citations on both paths at once — which is the failure this type's existence is meant to make
    /// impossible to introduce on one path only.
    /// </remarks>
    [GeneratedRegex(@"\[ctx:(?<id>[^\]]+)\]")]
    private static partial Regex CitationPattern();
}
