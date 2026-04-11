// Dump Ghidra DVP/VU overlay instruction listings from the current program.
// @category map_tools_ps2

import java.io.File;
import java.io.PrintWriter;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.mem.MemoryBlock;

public class GhidraDumpDvpListing extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        File output = args.length > 0 ? new File(args[0]) : askFile("DVP listing output", "Save");

        try (PrintWriter writer = new PrintWriter(output, "UTF-8")) {
            for (MemoryBlock block : currentProgram.getMemory().getBlocks()) {
                String name = block.getName();
                if (!name.startsWith(".DVP.overlay..")) {
                    continue;
                }

                writer.printf("# %s %s-%s size=0x%x%n", name, block.getStart(), block.getEnd(), block.getSize());
                InstructionIterator it = currentProgram.getListing().getInstructions(block.getStart(), true);
                int count = 0;
                while (it.hasNext()) {
                    Instruction instruction = it.next();
                    Address address = instruction.getAddress();
                    if (address.compareTo(block.getEnd()) > 0) {
                        break;
                    }
                    writer.printf("%s: %s%n", address, instruction);
                    count++;
                }
                writer.printf("# instructions=%d%n%n", count);
            }
        }

        println("Wrote DVP listing to " + output.getAbsolutePath());
    }
}
