using Nexus.Intelligence.LiveSmokeHost;

// W7G.2 Gate 9: the AI Head's live provider smoke host.
//
//   send "<prompt>"   -> runs a REAL turn through the governed path and the real OpenAI adapter,
//                        persists what the caller was given, prints the record
//   recv <recordId>   -> prints the persisted assistant output; run in a FRESH process to prove it
//                        survived the process that produced it
//
// The restart assertion needs two processes and no process can restart itself, which is why this
// host exists as a separate executable rather than as a helper inside the test assembly.

if (args.Length == 0)
{
    Console.Error.WriteLine("usage: LiveSmokeHost send \"<prompt>\" | LiveSmokeHost recv <recordId>");
    return 1;
}

if (!LiveProviderKey.Available())
{
    Console.Error.WriteLine(LiveProviderKey.SkipReason);
    return 2;
}

switch (args[0].ToLowerInvariant())
{
    case "send":
    {
        var prompt = args.Length > 1 ? args[1] : "Reply with exactly one word: pong";

        await using var estate = await LiveEstate.StartAsync();
        var response = await estate.ChatAsync(prompt);
        var record = LiveTurnRecord.From(response, prompt);

        LiveChatStore.Save(record);

        // Printed as separate lines rather than as the record, so a reader of the console output
        // sees what was asserted on. None of these values is a credential: every one of them is
        // something the vendor returned to a caller.
        Console.WriteLine($"ID={record.RecordId}");
        Console.WriteLine($"EXECUTION={record.ExecutionId}");
        Console.WriteLine($"TOKENS_IN={record.InputTokens}");
        Console.WriteLine($"TOKENS_OUT={record.OutputTokens}");
        Console.WriteLine($"ASSISTANT={record.AssistantOutput}");

        return string.IsNullOrWhiteSpace(record.AssistantOutput) ? 3 : 0;
    }

    case "recv":
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("recv requires <recordId>");
            return 4;
        }

        var record = LiveChatStore.Load(args[1]);

        if (record is null)
        {
            Console.WriteLine($"<no record {args[1]} in {LiveChatStore.DataDirectory}>");
            return 5;
        }

        // Only the assistant output, so the parent process can compare it verbatim against what the
        // writing process reported. Anything else on stdout would have to be stripped.
        Console.WriteLine(record.AssistantOutput);
        return 0;
    }

    default:
        Console.Error.WriteLine($"unknown command: {args[0]}");
        return 6;
}
