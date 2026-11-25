// Apply fnmatch names (optional) and decompile a list of functions to C files.
// args: <names.tsv or -> <function-list file> <outdir> <thumbBase-hex or -> <thumbEnd-hex or ->
// @category R26
import java.io.*;
import java.math.BigInteger;
import java.nio.file.*;
import java.util.*;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.cmd.function.CreateFunctionCmd;
import ghidra.app.decompiler.*;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.SourceType;

public class R26Decomp extends GhidraScript {
	@Override
	protected void run() throws Exception {
		String[] a = getScriptArgs();
		String tsv = a[0], list = a[1], outdir = a[2];
		AddressSpace sp = currentProgram.getAddressFactory().getDefaultAddressSpace();

		if (!a[3].equals("-")) {
			Register tm = currentProgram.getProgramContext().getRegister("TMode");
			Address s = sp.getAddress(Long.parseLong(a[3], 16));
			Address e = sp.getAddress(Long.parseLong(a[4], 16));
			currentProgram.getProgramContext().setValue(tm, s, e, BigInteger.ONE);
		}

		if (!tsv.equals("-")) {
			int n = 0;
			for (String line : Files.readAllLines(Paths.get(tsv))) {
				String[] f = line.split("\t");
				if (f.length < 5 || !f[3].equals("unique"))
					continue;
				Address ad = sp.getAddress(Long.decode(f[4]));
				new DisassembleCommand(ad, null, true).applyTo(currentProgram, monitor);
				Function fn = getFunctionAt(ad);
				if (fn == null) {
					new CreateFunctionCmd(ad).applyTo(currentProgram, monitor);
					fn = getFunctionAt(ad);
				}
				if (fn != null) {
					fn.setName(f[0], SourceType.IMPORTED);
					n++;
				}
			}
			println("named " + n + " functions");
		}

		DecompInterface di = new DecompInterface();
		di.openProgram(currentProgram);
		Files.createDirectories(Paths.get(outdir));
		for (String name : Files.readAllLines(Paths.get(list))) {
			name = name.trim();
			if (name.isEmpty())
				continue;
			Function fn = null;
			String label = name;
			if (name.contains("\t")) {
				String[] p = name.split("\t");
				label = p[0];
				name = p[1];
			}
			if (name.startsWith("0x")) {
				Address ad = sp.getAddress(Long.decode(name));
				new DisassembleCommand(ad, null, true).applyTo(currentProgram, monitor);
				fn = getFunctionAt(ad);
				if (fn == null) {
					new CreateFunctionCmd(ad).applyTo(currentProgram, monitor);
					fn = getFunctionAt(ad);
				}
			} else {
				for (Function f : currentProgram.getFunctionManager().getFunctions(true))
					if (f.getName().equals(name)) { fn = f; break; }
			}
			if (fn == null) {
				println("MISSING " + name);
				continue;
			}
			DecompileResults r = di.decompileFunction(fn, 120, monitor);
			String c = r.decompileCompleted() ? r.getDecompiledFunction().getC() : ("// failed: " + r.getErrorMessage());
			Files.writeString(Paths.get(outdir, label + ".c"), c);
		}
	}
}
