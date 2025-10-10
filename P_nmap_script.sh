#!/bin/bash

: "${RTSP_USER:?RTSP_USER not set}"
: "${RTSP_PASS:?RTSP_PASS not set}"

IP=$(nmap -p 554 --open -oG - $(ip -o -4 addr show $(ip route show default | awk '/default/ {print $5}') | awk '{print $4}') | awk '/554\/open/ {print $2}')
for ip in $IP; do
    echo "Checking $ip..."
    # Try connecting with ffprobe
    if ffprobe -v error -show_streams -rtsp_transport tcp -i "rtsp://$RTSP_USER:$RTSP_PASS@$ip:554/Streaming/Channels/201" 2>/dev/null | grep -q "codec_type=video"; then
        echo "IP=$ip" >> $GITHUB_ENV
        exit 0
    else
        echo "No video stream"
    fi
done

#assumptions ipv4 and 554 ports are rtsp
#add documentation for hardcoded args