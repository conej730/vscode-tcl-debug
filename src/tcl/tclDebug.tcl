#!/usr/bin/env tclsh

#
# Copyright (c) FlightAware 2018. All rights reserved
# Licensed under the MIT License.  See License.txt for license information
#

package require yajltcl
package require Tclx

set runDir [file dirname [info script]]
source [file join $runDir debugger.tcl]

set ::response_seq 1

proc parse_header {header} {
	set header [regsub {:} $header {}]
	if {[llength $header] != 2} {
		error "header should consist of key/value, llength = 2, but does not"
	}
	return [lindex $header 1]
}

proc check_arguments {_request} {
	upvar $_request request
	if {![info exists request(arguments)]} {
		error "request is missing required arguments"
	}
}

proc create_response {seq command _body} {
	global response_seq
	upvar $_body body

	yajl create doc
	doc map_open string seq integer $response_seq \
		string type string response \
		string request_seq integer $seq \
		string success bool true \
		string command string $command \
		string body map_open

	foreach {key value} [array get body] {
		set type string
		if {$key eq "breakpoints"} {
			doc string breakpoints array_open
			foreach {line verified} $value {
				doc map_open string line integer $line string verified bool $verified map_close
			}
			doc array_close
			continue
		}
		if {$key eq "threads"} {
			doc string threads array_open
			foreach {id name} $value {
				doc map_open string id integer $id string name string $name map_close
			}
			doc array_close
			continue
		}
		if {$key eq "stackTrace"} {
			doc string stackFrames array_open
			set stacks 0
			foreach stack [lreverse $value] {
				lassign $stack level loc type args
				# if {$level != 0} {
					doc map_open string id integer $level \
						string name string [expr {$type eq "global" ? $type : $args}] \
						string line integer [expr {$loc ne {} ? [loc::getLine $loc] : 0}] \
						string column integer 0
					if {$type eq "source"} {
						doc string source map_open string path string $args map_close
					} elseif {$type eq "proc"} {
						set source [blk::getFile [loc::getBlock $loc]]
						doc string source map_open string path string $source map_close
					}
					doc map_close
					incr stacks
				# }
			}
			doc array_close string totalFrames integer $stacks
			continue
		}
		if {$key eq "scopes"} {
			lassign $value level loc type args
			set name [expr {$type eq "proc" ? "Locals" : "Globals"}]
			doc string scopes array_open \
				map_open string name string $name \
				string variablesReference integer [expr {$level + 1}] \
				string namedVariables integer [llength [dbg::getVariables $level]] \
				string expensive bool false \
				map_close array_close
			continue
		}
		if {$key eq "variables"} {
			set level [expr {$value - 1}]
			foreach var [dbg::getVariables $level] {
				lappend vars [lindex $var 0]
			}
			doc string variables array_open
				foreach var [dbg::getVar $level -1 $vars] {
					lassign $var varName type varValue
					doc map_open string name string $varName \
						string value string $varValue \
						string type string [expr {$type eq "a" ? "array" : "string"}] \
						string variablesReference integer 0 \
						map_close
				}
			doc array_close
			continue
		}
		if {[string is integer -strict $value]} {
			set type integer
		} elseif {[string is boolean -strict $value]} {
			set type bool
		}
		doc string $key $type $value
	}

	doc map_close map_close
	set response [doc get]
	doc delete
	incr ::response_seq
	return $response
}

proc create_stopped_event {reason description threadId} {
	global response_seq

	yajl create doc
	doc map_open string seq integer $response_seq \
		string type string event \
		string event string stopped \
		string body map_open \
			string reason string $reason \
			string description string $description \
			string threadId integer $threadId \
		map_close map_close
	set event [doc get]
	doc delete
	incr ::response_seq
	return $event
}

proc send_terminate_event {} {
	global response_seq

	yajl create doc
	doc map_open string seq integer $response_seq \
		string type string event \
		string event string terminated \
		string body map_open \
		map_close map_close
	set event [doc get]
	doc delete
	incr ::response_seq
	transmit_data $event
}

proc send_exit_event {args} {
	global response_seq

	yajl create doc
	doc map_open string seq integer $response_seq \
		string type string event \
		string event string exited \
		string body map_open \
			string exitCode integer 0 \
		map_close map_close
	set event [doc get]
	doc delete
	incr ::response_seq
	transmit_data $event
}

proc error_response {seq command message} {
	yajl create doc
	doc map_open string seq integer $::response_seq \
		string type string response \
		string request_seq integer $seq \
		string success bool false \
		string message string $message \
		map_close
	set errorResponse [doc get]
	doc delete
	incr ::response_seq
	return $errorResponse
}

proc send_capabilities {seq} {
	set body(supportsConfigurationDoneRequest) true
	# set body(supportsSetVariable) true
	# set body(supportsFunctionBreakpoints) true
	set body(supportsTerminateRequest) true

	transmit_data [create_response $seq initialize body]
	return 0
}

proc send_initialized {} {
	yajl create doc
	doc map_open string seq integer $::response_seq string type string event string event string initialized map_close
	set event [doc get]
	doc delete
	incr ::response_seq
	transmit_data $event
	return 0
}

proc parse_initialize {_args seq} {
	upvar $_args args
	set ::columnsStartAt1 [string is true -strict $args(linesStartAt1)]
	set ::linesStartAt1 [string is true -strict $args(columnsStartAt1)]
	set ::locale $args(locale)
	set ::projName $args(clientID)

	send_capabilities $seq
	send_initialized
	return 0
}

proc launch_debugger {_args seq} {
	global fh
	upvar $_args args

	if {![info exists args(program)]} {
		transmit_data [error_response $seq launch "Launch request missing program"]
		return
	}
	if {![info exists args(args)]} {
		transmit_data [error_response $seq launch "Launch request missing script arguments"]
		return
	}

	set debugVars(interp) "/usr/local/bin/tclsh"
	set debugVars(dir) {}
	set debugVars(script) $args(program)
	set debugVars(scriptArgs) $args(args)
	set debugVars(projName) $::projName
	set startCmd [expr {[info exists args(stopOnEntry)] && $args(stopOnEntry) ? "dbg::step" : "dbg::run"}]

	if {[catch {
		::debugger::setDebugVars [array get debugVars]
		::debugger::init
		::debugger::start $startCmd
	} err] == 1} {
		transmit_data [error_response $seq launch "$err\ntrace: $errorInfo"]
		return
	}

	set ::launch_seq $seq
	return 0
}

proc transmit_data {msg} {
	global fh

	set res "Content-Length: [string length $msg]\r\n\r\n$msg"
	puts $fh $res
	flush $fh
	puts $res
	return 0
}

proc parse_content {content} {
	set request [::yajl::json2dict $content]
	if {![dict exists $request type] || ![dict exists $request seq]} {
		error "message is lacking required field type or seq"
	}
	set seq [dict get $request seq]
	switch [dict get $request type] {
		request {
			if {![dict exists $request command]} {
				error "request message is lacking required field command"
			}
			set command [dict get $request command]
			switch $command {
				initialize {
					array set arguments [dict get $request arguments]
					parse_initialize arguments $seq
				}
				launch {
					array set arguments [dict get $request arguments]
					launch_debugger arguments $seq
				}
				setBreakpoints {
					array set arguments [dict get $request arguments]
					vwait ::debuggerReady
					set body(breakpoints) [debugger::setBreakpoints arguments]
					transmit_data [create_response $seq $command body]
				}
				setExceptionBreakpoints {
					transmit_data [create_response $seq $command {}]
				}
				configurationDone {
					transmit_data [create_response $seq $command {}]
				}
				threads {
					set body(threads) {1 main}
					transmit_data [create_response $seq $command body]
					if {[info exists ::launch_seq]} {
						transmit_data [create_response $::launch_seq launch {}]
						unset -nocomplain ::launch_seq
						debugger::run run
					}
				}
				stackTrace {
					set body(stackTrace) [dbg::getStack]
					transmit_data [create_response $seq $command body]
				}
				scopes {
					set stacks [dbg::getStack]
					set frameId [dict get $request arguments frameId]
					set stackIndex [lsearch -index 0 $stacks $frameId]
					set body(scopes) [lindex $stacks $stackIndex]
					transmit_data [create_response $seq $command body]
				}
				variables {
					set body(variables) [dict get $request arguments variablesReference]
					transmit_data [create_response $seq $command body]
				}
				continue {
					debugger::run run
					transmit_data [create_response $seq $command {}]
				}
				next {
					debugger::run over
					transmit_data [create_response $seq $command {}]
				}
				terminate {
					transmit_data [create_response $seq $command {}]
					debugger::exitHandler
				}
			}
		}
	}
	return 0
}

proc debugger_linebreak {args} {
	if {[info exists ::launch_seq]} {
		set ::debuggerReady 1
		return
	}
	transmit_data [create_stopped_event breakpoint "Paused at breakpoint" 1]
}

proc shutdown {} {
	set ::die 1
}

proc getReadable { f } {
	global fh
	set status [catch {gets $f line} result]
	if {$status != 0 } {
		puts stderr "Error reading stdin"
		set ::die 1
	} elseif {$result >= 0} {
		puts $fh "line: $line"
		flush $fh
		if {[catch {parse_header $line} bytes] == 1} {
			puts $fh "Error: $bytes"
			flush $fh
		} else {
			set content [read stdin [expr {$bytes + 1}]]
			set content [string trim $content]
			puts $fh $content
			flush $fh
			if {[catch {parse_content $content} res] == 1} {
				puts $fh "Error with parse_content: $res"
			}
			flush $fh
		}
	} elseif { [fblocked $f] } {
		return
	} else {
		puts stderr "something wrong with stdin"
		set ::die 1
	}
}

proc main {argv} {
	global fh
	signal trap SIGINT shutdown
	signal trap SIGTERM shutdown

	set fh [open "/tmp/out.log" w]

	debugger::register linebreak debugger_linebreak

	fconfigure stdin -blocking false
	fileevent stdin readable [list getReadable stdin]

	vwait ::die

	puts $fh "exiting"
	close $fh
}

if {!$tcl_interactive} {
	main $argv
}