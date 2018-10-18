
namespace eval debugger {
	variable interp
	variable dir
	variable script
	variable scriptArgs
	variable projName

	variable libdir [file join [file dirname [info script]] lib/tcldebugger]
	variable instrumentDynamic 1
	variable doInstrument {*}
	variable dontInstrument {}
	variable autoLoad 0
	variable errorAction 1
	variable validEvents {attached linebreak}
	variable registeredEvent
}

source [file join $::debugger::libdir dbg.tcl]
source [file join $::debugger::libdir break.tcl]
source [file join $::debugger::libdir block.tcl]
source [file join $::debugger::libdir instrument.tcl]
source [file join $::debugger::libdir coverage.tcl]
source [file join $::debugger::libdir system.tcl]
source [file join $::debugger::libdir location.tcl]
source [file join $::debugger::libdir util.tcl]

source [file join $::debugger::libdir uplevel.pdx]
source [file join $::debugger::libdir tcltest.pdx]
source [file join $::debugger::libdir oratcl.pdx]
source [file join $::debugger::libdir tclCom.pdx]
source [file join $::debugger::libdir xmlGen.pdx]

proc debugger::init {} {
	variable libdir
	variable attachCmd {}
	variable afterTime 500
	variable afterID

	TestForSockets

	dbg::register linebreak  {debugger::linebreakHandler}
    dbg::register varbreak   {debugger::varbreakHandler}
    dbg::register userbreak  {debugger::userbreakHandler}
    dbg::register cmdresult  {debugger::cmdresultHandler}
    dbg::register exit       {debugger::exitHandler}
    dbg::register error      {debugger::errorHandler}
    dbg::register result     {debugger::resultHandler}
    dbg::register attach     {debugger::attachHandler}
    dbg::register instrument {debugger::instrumentHandler}


	dbg::initialize $libdir
}

proc debugger::start {cmd} {
	variable dir
	variable script
	variable interp
	variable scriptArgs
	variable projName

	set script [file join $dir $script]

	if {![dbg::setServerPort random]} {
		error "Error setting random port for debugger"
	}

	if {[catch {dbg::start $interp $dir $script $scriptArgs $projName} msg] == 1} {
		error "Application Initialization Error: $msg"
	} else {
		if {$cmd == "dbg::run"} {
			set cmd "dbg::step run"
		} elseif {$cmd == "dbg::step"} {
			set cmd "dbg::step any"
		}
		set debugger::attachCmd $cmd

		return 1
	}

	return 0
}

proc TestForSockets {} {
    proc dummy {args} {error dummy}
    if {[catch {set socket [socket -server dummy 0]} msg]} {
		error "Error: Unable to create socket"
    }
    close $socket
    rename dummy ""
}

#
# setDebugVars - expects a key/value list of variables for the debug init.  Supported
# 	keys are {interp dir script scriptArgs projName}
#
# @returns 0 on success
#
proc debugger::setDebugVars {debugVars} {
	if {[llength $debugVars] % 2 != 0} {
		error "setDebugVars should have key/value pairs.  Uneven set of elements received.  [llength $debugVars] args: $debugVars"
	}

	foreach {key value} $debugVars {
		if {$key ni {interp dir script scriptArgs projName}} {
			error "Invalid key received: $key  Must be interp, dir, script, scriptArgs, projName"
		}
		set ::debugger::$key $value
	}

	return 0
}

proc debugger::run {cmd} {
	if {$cmd eq ""} {
		set cmd $debugger::attachCmd
	} else {
		switch $cmd {
			run {
				set cmd "::dbg::run"
			}
			over {
				set cmd "::dbg::step over"
			}
			any {
				set cmd "::dbg::step any"
			}
		}
	}

	if {$dbg::appState == "dead"} {
		debugger::start $cmd
	}

	return [eval $cmd]
}

proc debugger::register {event callback} {
	variable registeredEvent
	variable validEvents

	if {$event ni $validEvents} {
		error "$event is not a valid event"
	}
	set registeredEvent($event) $callback
	return 0
}

proc debugger::setBreakpoints {_arguments} {
	upvar $_arguments arguments

	array set source $arguments(source)
	set block $::blk::blockFiles([system::formatFilename $source(path)])
	set body {}
	foreach break $arguments(breakpoints) {
		lassign $break type pos
		if {$type eq "line"} {
			set loc [loc::makeLocation $block [lindex $break 1]]
			dbg::addLineBreakpoint $loc
			lappend body $pos true
		}
	}
	return $body
}

proc debugger::linebreakHandler {args} {
	variable registeredEvent

	set loc [dbg::getPC]
	set blk [loc::getBlock $loc]
	set line [loc::getLine $loc]
	set range [loc::getRange $loc]
	set file [blk::getFile $blk]
	set ver [blk::getVersion $blk]

	if {[info exists registeredEvent(linebreak)]} {
		catch {uplevel #0 $registeredEvent(linebreak) $args} err
	}
}

proc debugger::varbreakHandler {args} {
	puts stderr "hit a bar break with args $args"
}

proc debugger::userbreakHandler {args} {
	puts stderr "hit a user break with args $args"
}

proc debugger::cmdresultHandler {args} {
	puts stderr "hit a cmd result with args $args"
}

proc debugger::exitHandler {args} {
	catch {dbg::quit}
	send_terminate_event
	if {[catch {send_exit_event $args} err] == 1} {
		puts stderr "an err? $err"
	}
}

proc debugger::errorHandler {args} {
	puts stderr "hit error with args $args"
}

proc debugger::resultHandler {args} {
	puts stderr "hit result with args $args"
}

proc debugger::attachHandler {projName} {
	variable registeredEvent

	if {[info exists registeredEvent(attached)]} {
		uplevel #0 $registeredEvent(attached) $projName
	}

	set debugger::afterID [after $debugger::afterTime {
		debugger::run $debugger::attachCmd
	}]
}

proc debugger::instrumentHandler {status block} {
	return
}

proc debugger::stoppedHandler {breakType} {
	if {[info exists debugger::afterID]} {
		after cancel $debugger::afterID
	}
}

