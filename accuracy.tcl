# Calculate the accuracy of the games in a database.
# Usage:
#   scid.exe accuracy.tcl engine.exe input_database.pgn

# Engine configuration
set engine_options {}
lappend engine_options [list MultiPV 1]
lappend engine_options [list Threads 4]
lappend engine_options [list Hash 1024]
set engine_limits {}
lappend engine_limits [list depth 40]
# lappend engine_limits [list movetime 600000]

proc new_accuracy {} {
    set ::prev_best_move ""
    set ::prev_best_move_evaluation 0
    return {}
}

proc move_classification {accuracy} {
    if {$accuracy > 1.0} { return "Unreal" }
    if {$accuracy == 1} { return "Perfect" }
    if {$accuracy > 0.9} { return "Great" }
    if {$accuracy > 0.8} { return "Good" }
    if {$accuracy > 0.6} { return "Inaccurate" }
    if {$accuracy > 0.4} { return "Mistake" }
    return "Blunder"
}

# Accuracy Calculation:
# 1. Compute the centipawn loss.
# 2. Adjust the decay factor based on the previous best evaluation.
# 3. Determine accuracy by applying a decay function to the centipawn loss.
# 4. Classify the move based on its accuracy.
proc update_accuracy {accuracy_list last_move} {
    # The last evaluations received from the engine were stored in a global array
    lassign $::enginePVs(1) score_pv1 score_type1 pv1
    if {$score_type1 eq "mate"} { set score_pv1 [expr {$score_pv1 < 0 ? -9999 : 9999}] }

    if {$::prev_best_move eq $last_move} {
        set cp_loss 0
        set accuracy 1
        set classification "Engine"
    } else {
        # score_pv1 is from the opponent POV: prev_best_move_evaluation - -1 * score_pv1
        set cp_loss [expr {$::prev_best_move_evaluation + $score_pv1}]
        set decay [expr {$::prev_best_move_evaluation / 1000000.0 - 0.003}]
        set accuracy [expr {2 * exp($decay * $cp_loss) - 1}]
        set classification [move_classification $accuracy]
    }

    # Store the expected best move for the next iteration
    set ::prev_best_move $::engineBestMove
    set ::prev_best_move_evaluation $score_pv1

    if {$last_move ne ""} {
        puts "[format "%6s" $last_move]  cp_loss: [format "%-4d" $cp_loss]  accuracy: [format "%6.2f%%"  [expr {$accuracy * 100}]]  $classification"
    }

    lappend accuracy_list $last_move $classification $accuracy $cp_loss
    return $accuracy_list
}

proc move_classification {accuracy} {
    if {$accuracy > 1.0} { return "Unreal" }
    if {$accuracy == 1} { return "Perfect" }
    if {$accuracy > 0.9} { return "Great" }
    if {$accuracy > 0.8} { return "Good" }
    if {$accuracy > 0.6} { return "Inaccurate" }
    if {$accuracy > 0.4} { return "Mistake" }
    return "Blunder"
}

# Count the moves for each classification and calculate the average centipawn loss and accuracy.
# Accuracy is adjusted to a (0,1) range before the average calculation.
proc reduce_accuracy_list {accuracy_list} {
    set n_accuracy 0
    set n_cp_loss 0
    array set res [list accuracy 0 cp_loss 0]
    foreach {last_move classification accuracy cp_loss} $accuracy_list {
        set clamp_accuracy [expr {max(0, min(1, $accuracy))}]
        set res(accuracy) [expr {$res(accuracy) + $clamp_accuracy}]
        incr n_accuracy
        set res(cp_loss) [expr {$res(cp_loss) + $cp_loss}]
        incr n_cp_loss
        if {![info exist res($classification)]} {
            set res($classification) 0
        }
        incr res($classification)
    }
    if {$n_accuracy > 0} {
        set res(accuracy) [expr {$res(accuracy) / $n_accuracy}]
        set res(cp_loss) [expr {$res(cp_loss) / $n_cp_loss}]
    }
    return [array get res]
}

# Parse input args
lassign $argv engine_exe input_database
set engine_exe [file nativename $engine_exe]
set input_database [file nativename $input_database]
if {$engine_exe eq "" || $input_database eq ""} {
    error "Usage: scid extract.tcl engine.exe input_database"
}

# Load the engine module from scid
set scidDir [file nativename [file dirname [info nameofexecutable]]]
source -encoding utf-8 [file nativename [file join $::scidDir "tcl" "enginecomm.tcl"]]

# Callbacks from the engines
# Store the latest PV into the global array ::enginePV(PV)
# Store the bestmove into the global variable ::engineBestMove
proc engine_messages {msg} {
    lassign $msg msgType msgData
    if {$msgType eq "InfoPV"} {
        lassign $msgData multipv depth seldepth nodes nps hashfull tbhits time score score_type score_wdl pv
        set ::enginePVs($multipv) [list $score $score_type $pv]
    } elseif {$msgType eq "InfoBestMove"} {
        lassign $msgData ::engineBestMove
        set ::engine_done 1
    }
}

# Open the engine
::engine::setLogCmd engine1 {}
::engine::connect engine1 engine_messages $engine_exe {}
::engine::send engine1 SetOptions $engine_options

# Open the database
set codec SCID5
if {[string equal -nocase ".pgn" [file extension $input_database]]} {
    set codec PGN
}
set base [sc_base open $codec $input_database]

# Iterate every position
set nGames [sc_base numGames $base]
for {set i 1} {$i <= $nGames} {incr i} {
    ::engine::send engine1 NewGame [list analysis post_pv post_wdl]
    sc_game load $i
    puts "[sc_game info white] - [sc_game info black]"
    set player(white) [new_accuracy]
    set player(black) [new_accuracy]
    set player(dummy_1st_move) [new_accuracy]
    set last_to_move "dummy_1st_move"
    while 1 {
        unset -nocomplain ::enginePVs
        set ::enginePVs(1) {}
        ::engine::send engine1 Go [list [sc_game UCI_currentPos] $engine_limits]
        vwait ::engine_done
        set player($last_to_move) [update_accuracy $player($last_to_move) [sc_game info previousMoveUCI]]
        if {[sc_pos isAt end]} break
        sc_move forward
        set last_to_move [expr {$last_to_move eq "white" ? "black" : "white"}]
    }
    foreach {key} {"white" "black"} {
        puts "$key:"
        foreach {key value} [reduce_accuracy_list $player($key)] {
            if {$key eq "accuracy"} {
                set value [format "%.2f%%" [expr {$value * 100}]]
            }
            puts "  $key: $value"
        }
    }
    puts "--------------------------"
}

# Clean up
::engine::close engine1
sc_base close $base
