-- E2E smoke assertions for a *running* MyIDE, driven through the Accessibility API.
-- Requires the controlling terminal to have Accessibility permission
-- (System Settings → Privacy & Security → Accessibility). Errors -1719/-25211 mean
-- permission hasn't been granted yet.
on run arguments
	set appName to "MyIDE"
	set targetPID to missing value
	if (count of arguments) > 0 then set targetPID to (item 1 of arguments as integer)
	tell application "System Events"
		if targetPID is missing value then
			if not (exists process appName) then error "MyIDE process is not running"
			set targetProcess to process appName
		else
			set targetProcess to missing value
			repeat with candidate in processes
				if (unix id of candidate) is targetPID then
					set targetProcess to candidate
					exit repeat
				end if
			end repeat
			if targetProcess is missing value then error "MyIDE process is not running"
		end if
		tell targetProcess
			set wasFrontmost to frontmost
			set winCount to 0
			repeat 40 times
				set winCount to (count of windows)
				if winCount > 0 then exit repeat
				delay 0.25
			end repeat
			if winCount < 1 then error "MyIDE has no windows"
			if wasFrontmost is false then set frontmost to true

			-- Best-effort: look for the code viewer's scroll area in the window subtree
			-- (there is no sidebar; the diff pane is the whole window).
			set contentFound to false
			try
				repeat with el in (entire contents of window 1)
					if (class of el) is scroll area then
						set contentFound to true
						exit repeat
					end if
				end repeat
			end try

			log "windows=" & winCount & " frontmost=" & wasFrontmost & " contentArea=" & contentFound
		end tell
	end tell
	return "ok"
end run
