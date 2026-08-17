namespace NexusAI.Domain.Memory;

public readonly record struct MemoryId(Guid Value)
{
    public static MemoryId New()
    {
        return new MemoryId(Guid.NewGuid());
    }

    public override string ToString()
    {
        return Value.ToString();
    }
}