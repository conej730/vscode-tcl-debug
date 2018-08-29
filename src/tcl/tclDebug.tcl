#!/usr/bin/env tclsh

#
# Copyright (c) FlightAware 2018. All rights reserved
# Licensed under the MIT License.  See License.txt for license information
#

package require yajltcl

set ::request_seq 1

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

proc send_capabilities {} {
	yajl create doc
	doc map_open string request_seq integer $::seq string type string response string body map_open \
		string supportsFunctionBreakpoints bool true \
		string supportTerminateDebuggee bool true \
		string supportsTerminateRequest bool true \
		map_close map_close
	set response [doc get]
	doc delete
	incr ::request_seq
	return $response
}

proc parse_initialize {_request} {
	upvar $_request request
	set ::columnsStartAt1 [string is true $request(linesStartAt1)]
	set ::linesStartAt1 [string is true -strict $request(columnsStartAt1)]
	set ::locale $request(locale)

	return [send_capabilities]
}

proc parse_content {content} {
	set request [::yajl::json2dict $content]
	if {![info exists request(command)]} {
		error "request is lacking command"
	}
	switch $request(command) {
		initialize {
			return [parse_initialize request]
		}
	}
}

proc handle_request {line} {
	lassign [split $line {\r\n\r\n}] header content
	set contentLength [parse_header $header]
	if {[string length $content] != $contentLength} {
		error "content length did not match header"
	}
	return [parse_content $content]
}

proc main {argv} {
	set fh {}
	while {[gets stdin line] > -1} {
		handle_request $line
	}
}

if {!$tcl_interactive} {
	main $argv
}