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

    # TODO use mktemp
    workspace="dynsdr"
    mkdir -p "$workspace"
    cd "$workspace"

    # rtl_sdr will be piped to rtl_sdr_input
    mkfifo rtl_sdr_input

    # This is the fifo that webrx will read from
    mkfifo rtl_sdr_output

    # Any time a new line containing a frequency is written to frequency_control, rtl_sdr will be restarted
    mkfifo frequency_control

    # Internal use. All writes to frequency_control are merged into this fifo
    mkfifo frequency_control_internal

    # Launch initial instance of rtl_sdr in the background
    launch_rtl_sdr

    # Background job for merging streams from multiple invocations of rtl_sdr
    copy_input_to_output &
    copy_input_to_output_pid=$!

    monitor_frequency_changes

    wait
}

# Merge streams from multiple invocations of rtl_sdr into a single fifo that
# will be open for the duration of the program, rtl_sdr_output.
copy_input_to_output() {
    while true; do
        (while true; do cat rtl_sdr_input; done) > rtl_sdr_output
    done
}

# Launch rtl_sdr in the background and store its pid in rtl_sdr_pid
# Yes, we need the pid of rtl_sdr itself, so that we can SIGINT it.
# it *has* to be SIGINT'd, otherwise the SDR driver gets in a weird
# state and you cant use it again from the same process group.
launch_rtl_sdr() {
    rtl_sdr -s "$sample_rate" -f "$frequency" -p "$ppm" -g "$gain" - > rtl_sdr_input &
    rtl_sdr_pid=$!
}

monitor_frequency_changes() {
    # Merge all writes to frequency_control into a single stream,
    # frequency_control_internal.
    # When one end of a FIFO closes, both ends close, so this is necessary to
    # keep frequency_control_internal open for the duration of the program.
    ((while true; do cat frequency_control; done) > frequency_control_internal) &
    monitor_frequency_changes_pid=$!

    # Only allow lines containing numbers from 0Hz to 100GHz (seems reasonable)
    cat frequency_control_internal \
        | grep --line-buffered '^[0-9]\{1,12\}$' \
        | while read -r freq; do
            echo "Changing to $freq. Killing $rtl_sdr_pid"
            kill -INT "$rtl_sdr_pid" || true
            wait "$rtl_sdr_pid" || true

            # Sleep just in case TODO is this necessary?
            sleep 0.1
            frequency="$freq"
            launch_rtl_sdr
            echo "Frequency changed. New pid is $rtl_sdr_pid"
        done
    kill "$monitor_frequency_changes_pid" || true
    wait "$monitor_frequency_changes_pid" || true
}

end() {
    trap - EXIT INT
    echo "Shutting down."
    if [ -n "$jobs" ]; then
        kill "$jobs"
    fi
    rm -v rtl_sdr_input rtl_sdr_output frequency_control frequency_control_internal
    echo "Done!"
    exit 0
}

main
