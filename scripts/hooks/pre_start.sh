#!/bin/bash

echo 'review_rabbit: pre_start'
OPEN_FILES_RECOMMENDED=24576
OPEN_FILES_LIMIT=$(ulimit -n)
export ERL_CRASH_DUMP=$(date +review_rabbit_%Y%m%d_%H:%M:%S.dump)
if [ "$OPEN_FILES_RECOMMENDED" -gt "$OPEN_FILES_LIMIT" ]; then
    echo "WARNING: ulimit -n is $OPEN_FILES_LIMIT; $OPEN_FILES_RECOMMENDED is the recommended minimum."
    echo "You are recommended to ensure the node is stopped and raise the maximum number of open files (try 'ulimit -n $OPEN_FILES_RECOMMENDED') before starting the node."
fi