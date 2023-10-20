# Calculate the accuracy of the games in a database.
# Usage:
#   scid.exe accuracy.tcl engine.exe input_database.pgn

# Engine configuration
set engine_options {}
lappend engine_options [list MultiPV 1]
lappend engine_options [list Threads 4]
lappend engine_options [list Hash 1024]
set engine_limits {}
lappend engine_limits [list depth 26]
lappend engine_limits [list movetime 600000]

proc new_accuracy {} {
    set ::prev_best_move ""
    set ::prev_best_move_evaluation 0
    return [list 0 0 0 0 0 0 0]
}

# Calculate accuracy:
# 1. Adjustment Tier: Multiplier based on the previous move's evaluation:
#    - Formula: Tier = 1 + 0.005 x | previous_evaluation |
# 2. Move Classification: Categorizes the move using the centipawn difference and the adjustment tier:
#    - "Perfect" if Difference <= 10
#    - "Good" if Difference <= 20 x Tier
#    - "Inaccurate" if Difference <= 50 x Tier
#    - "Mistake" if Difference <= 100 x Tier
#    - "Blunder" for all larger differences.
# 3. Game Accuracy: Weighted average of move classifications:
#    - Weights: 1.0, 0.8, 0.3, 0.1, 0.0
#    - Formula: Accuracy = SumOf(weighted_category_num_of_moves) / num_of_moves
proc update_accuracy {accuracy_list last_move} {
    # The last evaluations received from the engine are stored in a global array
    lassign $::enginePVs(1) score_pv1 score_type1 pv1
    if {$score_type1 eq "mate"} { set score_pv1 [expr {$score_pv1 < 0 ? -9999 : 9999}] }

    lassign $accuracy_list avg_cp_loss accuracy n_perf n_good n_inac n_mist n_blun
    if {$::prev_best_move eq $last_move} {
        set cp_difference 0
    } else {
        # score_pv1 is from the opponent POV: prev_best_move_evaluation - -1 * score_pv1
        set cp_difference [expr {$::prev_best_move_evaluation + $score_pv1}]
    }

    # Average cp loss
    set n_moves [expr {$n_perf + $n_good + $n_inac +$n_mist + $n_blun}]
    set total_cp_loss [expr {$avg_cp_loss * $n_moves}]
    incr n_moves
    set avg_cp_loss [expr {($total_cp_loss + $cp_difference) / $n_moves}]

    # Modified Tiered Move Analysis
    set adjust_tier [expr {1.0 + 0.005 * abs($::prev_best_move_evaluation)}]
    if {$cp_difference <= 10} {
        incr n_perf
    } elseif {$cp_difference <= 20 * $adjust_tier} {
        incr n_good
    } elseif {$cp_difference <= 50 * $adjust_tier} {
        incr n_inac
    } elseif {$cp_difference <= 100 * $adjust_tier} {
        incr n_mist
    } else {
        incr n_blun
    }

    # Calculate game accuracy
    set weighted [lmap v [list $n_perf $n_good $n_inac $n_mist $n_blun] w [list 1.0 0.8 0.3 0.1 0.0] { expr {1.0 * $v * $w }}]
    set accuracy 0.0
    foreach {value} $weighted {
        set accuracy [expr {$accuracy + $value}]
    }
    set accuracy [expr {$accuracy / $n_moves}]

    # Store the expected best move for the next iteration
    set ::prev_best_move $::engineBestMove
    set ::prev_best_move_evaluation $score_pv1

    return [list $avg_cp_loss $accuracy $n_perf $n_good $n_inac $n_mist $n_blun]
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
source -encoding utf-8 [file nativename [file join $::scidDir ".." "tcl" "enginecomm.tcl"]]

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
        lassign $player($key) avg_cp_loss accuracy n_perf n_good n_inac n_mist n_blun
        puts "$key:"
        puts "  Average CP Loss: $avg_cp_loss"
        puts "  Accuracy       : [format "%.2f%%" [expr {$accuracy * 100}]]"
        puts "  Best:[format %3d $n_perf]  Good:[format %3d $n_good]  Inaccuracies:[format %3d $n_inac]  Mistakes:[format %3d $n_mist]  Blunders:[format %3d $n_blun]"
    }
    puts "--------------------------"
}

# Clean up
::engine::close engine1
sc_base close $base
