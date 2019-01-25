#!/bin/sh

set -e

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <sample_rate> <center_freq> <ppm> <rf_gain>"
    exit 1
fi

sample_rate="$1"
frequency="$2"
ppm="$3"
gain="$4"


main() {
    # Set up traps for exiting
    trap end EXIT INT

    # old_workdir="$PWD"
    # workspace="$(mktemp -d)"
    # echo "$workspace"
    # cd "$workspace"

    # rtl_sdr will be send to rtl_sdr_input
    mkfifo rtl_sdr_input

    # This is the fifo that webrx will read from
    mkfifo rtl_sdr_output

    # Any time a new line containing a frequency is written to frequency_control, rtl_sdr will be restarted
    mkfifo frequency_control

    mkfifo frequency_control_internal

    # Start initial jobs
    launch_rtl_sdr
    copy_input_to_output
    monitor_frequency_changes

    # monitor_frequency_changes &
    # monitor_frequency_changes_pid=$!

    wait
}


launch_rtl_sdr() {
    rtl_sdr -s "$sample_rate" -f "$frequency" -p "$ppm" -g "$gain" - > rtl_sdr_input &
    rtl_sdr_pid=$!
}

copy_input_to_output() {
    (while true; do
        (while true; do cat rtl_sdr_input; done) > rtl_sdr_output
    done) &
    copy_input_to_output_pid=$!
}

monitor_frequency_changes() {
    ((while true; do cat frequency_control; done) > frequency_control_internal) &
    monitor_frequency_changes_pid=$!
    # Only allow lines containing numbers from 0Hz to 100GHz (seems reasonable)
    cat frequency_control_internal \
        | grep --line-buffered '^[0-9]\{1,12\}$' \
        | while read -r freq; do
            echo "Changing to $freq. Killing $rtl_sdr_pid"
            kill -INT "$rtl_sdr_pid" || true
            echo "Killed"
            wait "$rtl_sdr_pid" || true
            echo "Done waiting"
            sleep 1
            frequency="$freq"
            launch_rtl_sdr
            echo "Frequency changed. New pid is $rtl_sdr_pid"
        done
    kill "$monitor_frequency_changes_pid" && (wait "$monitor_frequency_changes_pid" || true)
}

end() {
    kill "$rtl_sdr_pid" || true
    kill "$copy_input_to_output_pid" || true
    kill "$monitor_frequency_changes_pid" || true
    wait
    rm -v rtl_sdr_input rtl_sdr_output frequency_control frequency_control_internal
    echo "Done!"
    # cd "$old_workdir"
    # rmdir "$workspace"
    # rm rtl_sdr_output
    exit 0
}

main
