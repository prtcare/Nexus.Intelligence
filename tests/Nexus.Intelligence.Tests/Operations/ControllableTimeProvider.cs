namespace Nexus.Intelligence.Tests.Operations;

/// <summary>
/// A clock the test owns, so that a configured cooldown elapses because the test said so rather than
/// because the machine took a certain number of milliseconds to reach the next line.
/// </summary>
/// <remarks>
/// <para>
/// <b>This is the W7G.2 F-6 repair, and it is a test-only type.</b> Before it, a fixture could seed
/// history stamped from <see cref="DateTimeOffset.UtcNow"/> while the composed estate read
/// <see cref="TimeProvider.System"/>. Two clocks that agree only if the routing decision happens to be
/// reached quickly — which made an assertion about a circuit cooldown a measurement of JIT time. On a
/// cold isolated run the window was always missed and the test failed; in a warm full suite it was
/// always met and the test passed. Neither outcome was about the estate.
/// </para>
/// <para>
/// <b>Frozen, not merely injected.</b> Nothing advances this clock unless a test calls
/// <see cref="Advance"/>, so a difference between two instants is exactly the difference the test
/// chose. That is what makes a cold run and a warm run produce the same answer.
/// </para>
/// <para>
/// <b>Ticks are moved atomically.</b> Ticks are held in a <see cref="long"/> and read/written through
/// <see cref="Interlocked"/>, in the same shape as the recovery suite's clock: a test thread may move
/// the clock while another thread reads it, and a torn <see cref="DateTimeOffset"/> would be a flake of
/// exactly the kind this type exists to remove.
/// </para>
/// <para>
/// <b>Time only moves forward.</b> <see cref="Advance"/> refuses a negative interval rather than
/// allowing it, because a clock that can run backwards makes every cooldown assertion ambiguous — the
/// same reasoning the recovery suite's clock records.
/// </para>
/// </remarks>
internal sealed class ControllableTimeProvider : TimeProvider
{
    private long _utcTicks;

    /// <summary>The instant this clock starts from, and the value it holds until advanced.</summary>
    public static readonly DateTimeOffset Origin = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    /// <summary>Starts a clock at <see cref="Origin"/>.</summary>
    public ControllableTimeProvider()
        : this(Origin)
    {
    }

    /// <summary>Starts a clock at an instant the caller names.</summary>
    public ControllableTimeProvider(DateTimeOffset start) => _utcTicks = start.UtcTicks;

    /// <inheritdoc />
    public override DateTimeOffset GetUtcNow() => new(Interlocked.Read(ref _utcTicks), TimeSpan.Zero);

    /// <summary>Moves the clock forward. Time in this estate only ever moves on.</summary>
    public void Advance(TimeSpan by)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(by, TimeSpan.Zero);

        Interlocked.Add(ref _utcTicks, by.Ticks);
    }
}
