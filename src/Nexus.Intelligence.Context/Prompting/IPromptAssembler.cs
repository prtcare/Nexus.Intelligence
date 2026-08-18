namespace Nexus.Intelligence.Context.Prompting;

public interface IPromptAssembler
{
    AssembledPrompt Assemble(PromptRequest request);
}
