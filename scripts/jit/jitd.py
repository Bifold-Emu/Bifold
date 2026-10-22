"""Minimal stand-in for StikDebug's universal.js, run inside Xcode's lldb against a device.

Usage (lldb):  command script import jitd.py   then   jitserve <seconds> <logfile>
Handles `brk #0xf00d` with x16 = 1 (prepare region: allocate RX with `_M`, touch each 16 KB
page from the debugger, return the address in x0) and x16 = 0 (detach). Everything else is
continued, passing signals through.
"""
import time
import lldb

BRK_F00D = 0xD4200000 | (0xF00D << 5)
PAGE = 16384


def _reg(frame, name):
    return frame.FindRegister(name).GetValueAsUnsigned()


def jitserve(debugger, command, result, internal_dict):
    args = command.split()
    seconds = float(args[0]) if args else 60
    logpath = args[1] if len(args) > 1 else "/tmp/jitd.log"
    log = open(logpath, "a")

    def say(msg):
        log.write("%.2f %s\n" % (time.time(), msg))
        log.flush()

    # Synchronous loop, as in StikDebug's universal.js: continue, wait for the stop, handle it.
    debugger.SetAsync(False)
    process = debugger.GetSelectedTarget().GetProcess()
    say("attached pid=%d state=%d" % (process.GetProcessID(), process.GetState()))
    deadline = time.time() + seconds
    served = 0
    other = 0
    while process.IsValid() and time.time() < deadline:
        process.Continue()
        state = process.GetState()
        if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed):
            say("process ended state=%d exit=%d" % (state, process.GetExitStatus()))
            return
        handled = False
        for thread in process:
            if thread.GetStopReason() in (lldb.eStopReasonNone, lldb.eStopReasonInvalid):
                continue
            frame = thread.GetFrameAtIndex(0)
            pc = frame.GetPC()
            e = lldb.SBError()
            ins = process.ReadUnsignedFromMemory(pc, 4, e)
            if not e.Success() or ins != BRK_F00D:
                say("stop tid=%d reason=%d pc=0x%x desc=%s" % (
                    thread.GetThreadID(), thread.GetStopReason(), pc, thread.GetStopDescription(200)))
                continue
            handled = True
            x16, x0, x1 = _reg(frame, "x16"), _reg(frame, "x0"), _reg(frame, "x1")
            say("brk #0xf00d x16=%d x0=0x%x x1=0x%x" % (x16, x0, x1))
            if x16 == 1:
                addr = x0
                if addr == 0 and x1:
                    ae = lldb.SBError()
                    addr = process.AllocateMemory(x1, lldb.ePermissionsReadable | lldb.ePermissionsExecutable, ae)
                    say("_M rx size=0x%x -> 0x%x (%s)" % (x1, addr, ae.GetCString() or "ok"))
                if addr and x1:
                    t0 = time.time()
                    bad = 0
                    for off in range(0, x1, PAGE):
                        we = lldb.SBError()
                        if process.WriteMemory(addr + off, b"\x69", we) != 1:
                            bad += 1
                    say("touched %d pages in %.1fs, %d failed" % ((x1 + PAGE - 1) // PAGE, time.time() - t0, bad))
                frame.FindRegister("x0").SetValueFromCString("0x%x" % addr)
                frame.SetPC(pc + 4)
                served += 1
            elif x16 == 0:
                frame.SetPC(pc + 4)
                say("detach requested")
                process.Detach()
                return
            else:
                frame.SetPC(pc + 4)
                say("unknown command %d ignored" % x16)
        if not handled:
            other += 1
    say("%d stop(s) without a thread stop reason (lldb internal)" % other)
    say("deadline reached after %d region(s); detaching" % served)
    process.Detach()


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f jitd.jitserve jitserve")
