namespace Nexus.Intelligence.Context.Ranking;

// Deliberate, temporary boundary violation for the M-08-1.4 CI gate proof.
// "Conversation" is a product concept - exactly what NEXUS_ARCHITECTURE_V2.md
// section 2.3 forbids inside Nexus.Intelligence.*. This file is REVERTED by the
// commit that follows it; it exists only to prove the architecture-test step
// goes red in CI.
public sealed class Conversation
{
    public string Id { get; set; } = string.Empty;

    public string Title { get; set; } = string.Empty;
}
