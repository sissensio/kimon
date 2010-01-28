source redis.tcl

proc checkRedisWatchdog {host port key diff} {
    if {[catch {
        set r [redis $host $port]
        set val [$r get $key]
        $r close
        if {$val eq {}} {
            set ret "ko"
        } else {
            set d [expr {[clock seconds]-$val}]
            if {$d > $diff} {
                set ret "ko"
            } else {
                set ret "ok"
            }
        }
    } e]} {
        set ret "ko"
    }
    return $ret
}

proc handleRequest {fd ip port} {
    fconfigure $fd -translation binary
    set req {}

    while 1 {
        set buf [read $fd 1]
        if {$buf eq {}} {
            close $fd
            return
        }
        append req $buf
        if {[string first "\r\n\r\n" $req] != -1} break
    }
    puts -nonewline $fd [genReport]
    close $fd
}

proc getProcField {file field} {
    set fd [open /proc/$file r]
    set buf [read $fd]
    close $fd
    lindex [split $buf] $field
}

proc getRootPartitionUsage {} {
    set buf [exec df]
    foreach line [split $buf "\n"] {
        regsub -all { +} $line { } line
        set f [split $line]
        if {[lindex $f 5] eq "/"} {
            return [lindex $f 4]
        }
    }
    return "unknown"
}

proc getReplicationMasterStatus {} {
    set buf [exec echo "show master status" | mysql -u root]
    set lines [split $buf "\n"]
    regsub -all { +} [lindex $lines 1] { } line
    set fields [split $line " \t"]
    if {[lindex $fields 0] eq {}} {
        return {}
    }
    list [lindex $fields 0] [lindex $fields 1]
}

proc getReplicationSlaveStatus {} {
    set buf [exec echo "show slave status" | mysql -u root]
    set lines [split $buf "\n"]
    regsub -all { +} [lindex $lines 1] { } line
    set fields [split $line " \t"]
    if {[lindex $fields 0] eq {Connecting}} {
        return {}
    }
    for {set j 0} {$j < 100} {incr j} {
        if {[string first . [lindex $fields $j]] != -1} {
            return [list [lindex $fields $j] [lindex $fields [expr $j+1]]]
        }
    }
    return {}
}

proc genReport {} {
    set r {}
    append r "uptime_seconds: [expr int([getProcField uptime 0])]\n"
    append r "uptime_days: [expr int([getProcField uptime 0])/3600*24]\n"
    append r "load: [getProcField loadavg 0]\n"
    append r "disk_usage: [getRootPartitionUsage]\n"
    set rs [getReplicationMasterStatus]
    if {[llength $rs] != 0} {
        append r "replication_role: master\n"
        append r "replication_file: [lindex $rs 0]\n"
        append r "replication_pos: [lindex $rs 1]\n"
    }
    set rs [getReplicationSlaveStatus]
    if {[llength $rs] != 0} {
        append r "replication_role: slave\n"
        append r "replication_file: [lindex $rs 0]\n"
        append r "replication_pos: [lindex $rs 1]\n"
    }

    set fd [open /etc/kimon.conf r]
    while {[gets $fd line] != -1} {
        # watchdog 127.0.0.1 6380 global:last.fetch 60
        set fields [split $line]
        if {[lindex $fields 0] eq {watchdog}} {
            set v [checkRedisWatchdog [lindex $fields 2] \
                               [lindex $fields 3] \
                               [lindex $fields 4] \
                               [lindex $fields 5]]
            append r "[lindex $fields 1]: $v\r\n"
        }
    }
    close $fd

    append hdr "HTTP/1.0 200 OK\r\n"
    append hdr "Server: Kimon 1.0\r\n"
    append hdr "Connection: close\r\n"
    append hdr "Content-Length: [string length $r]\r\n"
    append hdr "Content-Type: text/plain\r\n\r\n"
    append hdr $r
    return $hdr
}

socket -server handleRequest 12345
vwait forever
