#!/usr/bin/env tclsh

set debugVars(interp) "/usr/local/bin/tclsh"
set debugVars(dir) {}
set debugVars(script) "/Users/jonathan.cone/dev/mock_debug/test.tcl"
set debugVars(scriptArgs) ""
set debugVars(projName) "vscode"
set startCmd "dbg::step"

source debugger.tcl
debugger::setDebugVars [array get debugVars]
debugger::init
debugger::start $startCmd
vwait forever
