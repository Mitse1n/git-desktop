#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swift build --product GitDesk
swift run GitDeskChecks
ui_sources=(Sources/GitDesk/*.swift)
ui_sources=(${ui_sources:#Sources/GitDesk/main.swift})
swiftc -I .build/debug/Modules .build/debug/GitDeskCore.build/*.o .build/debug/SwiftTerm.build/*.o "${ui_sources[@]}" Tests/GitDeskUITests/FlowChecks.swift Tests/GitDeskUITests/HistoryPaginationChecks.swift Tests/GitDeskUITests/HostingChecks.swift Tests/GitDeskUITests/main.swift -o .build/GitDeskUIChecks
.build/GitDeskUIChecks
