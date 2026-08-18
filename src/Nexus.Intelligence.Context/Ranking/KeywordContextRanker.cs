using System.Text.RegularExpressions;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Context.Ranking;

public sealed partial class KeywordContextRanker : IContextRanker
{
    private readonly TimeProvider _timeProvider;

    public KeywordContextRanker(TimeProvider timeProvider)
    {
        _timeProvider = timeProvider;
    }

    public IReadOnlyList<RankedContextItem> Rank(
        ContextBundle bundle, string query, RankingOptions options)
    {
        var terms = TokenPattern()
            .Split(query)
            .Where(token => token.Length > 0)
            .Select(t => t.ToLowerInvariant())
            .Distinct()
            .ToArray();

        var now = _timeProvider.GetUtcNow();

        return bundle.Items
            .Select(item => new RankedContextItem(item, Score(item, terms, options, now)))
            .OrderByDescending(ranked => ranked.Score)
            .Take(options.MaxItems)
            .ToList();
    }

    private static double Score(
        ContextItem item,
        IReadOnlyCollection<string> terms,
        RankingOptions options,
        DateTimeOffset now)
    {
        return KeywordOverlap(item, terms)
            * TrustWeight(item.Trust)
            * RecencyDecay(item.OccurredAt, options.RecencyHalfLifeDays, now)
            * (item.RelevanceHint ?? 1.0);
    }

    private static double KeywordOverlap(ContextItem item, IReadOnlyCollection<string> terms)
    {
        if (terms.Count == 0)
        {
            return 1.0;
        }

        var title = item.Title ?? string.Empty;

        var matches = terms.Count(term =>
            title.Contains(term, StringComparison.OrdinalIgnoreCase) ||
            item.Body.Contains(term, StringComparison.OrdinalIgnoreCase));

        return 0.15 + (0.85 * matches / terms.Count);
    }

    [GeneratedRegex(@"[^\p{L}\p{N}]+")]
    private static partial Regex TokenPattern();

    private static double TrustWeight(TrustLevel trust) => trust switch
    {
        TrustLevel.Unverified => 0.4,
        TrustLevel.Reported => 0.7,
        TrustLevel.Curated => 1.0,
        TrustLevel.Approved => 1.3,
        TrustLevel.Authoritative => 1.6,
        _ => throw new ArgumentOutOfRangeException(nameof(trust), trust, null)
    };

    private static double RecencyDecay(DateTimeOffset? occurredAt, double recencyHalfLifeDays, DateTimeOffset now)
    {
        if (occurredAt is null)
        {
            return 1.0;
        }

        var ageDays = (now - occurredAt.Value).TotalDays;
        return Math.Pow(0.5, ageDays / recencyHalfLifeDays);
    }
}
