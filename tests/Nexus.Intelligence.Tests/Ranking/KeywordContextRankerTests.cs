using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Contracts;
using Xunit;

namespace Nexus.Intelligence.Tests.Ranking;

public sealed class KeywordContextRankerTests
{
    private static readonly DateTimeOffset Now = new(2026, 8, 18, 0, 0, 0, TimeSpan.Zero);

    private static ContextItem Item(
        string id,
        TrustLevel trust,
        string body,
        string? title = null,
        DateTimeOffset? occurredAt = null)
    {
        return new ContextItem
        {
            Id = id,
            Kind = ContextItemKind.Fact,
            Title = title,
            Body = body,
            Trust = trust,
            OccurredAt = occurredAt
        };
    }

    [Fact]
    public void EmptyQuery_ReturnsTrustOrderedResults()
    {
        var ranker = new KeywordContextRanker(new FixedTimeProvider(Now));

        var bundle = new ContextBundle(
        [
            Item("unverified", TrustLevel.Unverified, "some content"),
            Item("authoritative", TrustLevel.Authoritative, "some content"),
            Item("curated", TrustLevel.Curated, "some content"),
            Item("approved", TrustLevel.Approved, "some content"),
            Item("reported", TrustLevel.Reported, "some content")
        ]);

        var ranked = ranker.Rank(bundle, "   ", RankingOptions.Default);

        Assert.Equal(
            ["authoritative", "approved", "curated", "reported", "unverified"],
            ranked.Select(r => r.Item.Id));
    }

    [Fact]
    public void ZeroOverlapAuthoritativeItem_CanOutrankFullOverlapUnverifiedItem()
    {
        var ranker = new KeywordContextRanker(new FixedTimeProvider(Now));

        var bundle = new ContextBundle(
        [
            Item(
                "authoritative-no-overlap",
                TrustLevel.Authoritative,
                "This shares no words with the query at all.",
                occurredAt: null),
            Item(
                "unverified-full-overlap",
                TrustLevel.Unverified,
                "decide next step",
                occurredAt: Now.AddDays(-300))
        ]);

        var ranked = ranker.Rank(bundle, "decide next step", RankingOptions.Default);

        Assert.Equal("authoritative-no-overlap", ranked[0].Item.Id);
        Assert.Equal("unverified-full-overlap", ranked[1].Item.Id);
        Assert.True(ranked[0].Score > ranked[1].Score);
    }

    [Fact]
    public void PunctuationAdjacentTerms_StillMatch()
    {
        var ranker = new KeywordContextRanker(new FixedTimeProvider(Now));

        var bundle = new ContextBundle(
        [
            Item("matching", TrustLevel.Curated, "We need to decide the next step."),
            Item("non-matching", TrustLevel.Curated, "Totally unrelated content.")
        ]);

        var ranked = ranker.Rank(bundle, "decide?", RankingOptions.Default);

        Assert.Equal("matching", ranked[0].Item.Id);
        Assert.Equal(1.0, ranked[0].Score, precision: 10);
        Assert.True(ranked[0].Score > ranked[1].Score);
    }

    private sealed class FixedTimeProvider(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }
}
