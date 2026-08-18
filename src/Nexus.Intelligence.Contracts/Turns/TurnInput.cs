namespace Nexus.Intelligence.Contracts;

public sealed record TurnInput(TurnInputKind Kind, string Text, IReadOnlyList<AttachmentRef> Attachments);
