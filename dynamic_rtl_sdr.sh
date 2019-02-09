#!/bin/sh

set -e

if [ "$#" -ne 8 ]; then
    echo "Usage: $0 <sample_rate> <center_freq> <ppm> <rf_gain> <nmux_bufsize> <nmux_bufcnt> <nmux_port> <nmux_addr>"
    exit 1
fi

sample_rate="$1"
frequency="$2"
ppm="$3"
gain="$4"
nmux_bufsize="$5"
nmux_bufcnt="$6"
nmux_port="$7"
nmux_addr="$8"


main() {
    # Set up traps for exiting
    trap end EXIT INT

    # TODO use mktemp
    workspace="dynsdr"
    mkdir -p "$workspace"
    cd "$workspace"

    # rtl_sdr will be piped to rtl_sdr_input
    if ! [ -p airspyhf_rx_input ]; then
        mkfifo airspyhf_rx_input
    fi

    # Any time a new line containing a frequency is written to frequency_control, rtl_sdr will be restarted
    if ! [ -p frequency_control ]; then
        mkfifo frequency_control
    fi

    # Internal use. All writes to frequency_control are merged into this fifo
    if ! [ -p frequency_control_internal ]; then
        mkfifo frequency_control_internal
    fi

    # Launch initial instance of rtl_sdr in the background
    launch_airspyhf_rx

    # Background job for merging streams from multiple invocations of rtl_sdr
    send_iq_to_nmux &
    send_iq_to_nmux_pid=$!

    monitor_frequency_changes

    wait
}

# Merge streams from multiple invocations of rtl_sdr and send it to nmux
send_iq_to_nmux() {
    while true; do
        (while true; do cat rtl_sdr_input; done) \
            | nmux --bufsize "$nmux_bufsize" --bufcnt "$nmux_bufcnt" --port "$nmux_port" --address "$nmux_addr"
    done
}

# Launch rtl_sdr in the background and store its pid in rtl_sdr_pid
# Yes, we need the pid of rtl_sdr itself, so that we can SIGINT it.
# it *has* to be SIGINT'd, otherwise the SDR driver gets in a weird
# state and you cant use it again from the same process group.
launch_airspyhf_rx() {
    airspyhf_rx -s "$sample_rate" -f "$frequency" -p "$ppm" -g "$gain" - > airspyhf_rx_input &
    airspyhf_rx_pid=$!
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
            echo "Changing to $freq. Killing $airspyhf_rx_pid"
            kill -INT "$airspyhf_rx_pid" || true
            wait "$airspyhf_rx_pid" || true

            # Sleep just in case TODO is this necessary?
            sleep 0.1
            frequency="$freq"
            launch_airspyhf_rx
            echo "Frequency changed. New pid is $airspyhf_rx_pid"
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
    rm -v airspyhf_rx_input frequency_control frequency_control_internal
    echo "Done!"
    exit 0
}

main
