#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swift run GitDeskChecks
swiftc Sources/GitDesk/ConsoleTextView.swift Tests/GitDeskUITests/main.swift -o .build/GitDeskUIChecks
.build/GitDeskUIChecks
