-- Ghostty shell integration for cmd with Clink
-- (https://chrisant996.github.io/clink/), v1.4.25 or later. Ghostty adds
-- this folder to %CLINK_PATH% when it starts cmd, so Clink loads it.
--
-- The PROMPT Ghostty gives cmd reports each prompt, but can't report the
-- exit status, and a Clink prompt (a custom one in particular) may replace
-- it. So this script takes Ghostty's codes out of cmd's prompt and sends
-- them around whatever prompt Clink shows:
--   OSC 133;D;status  the last command's exit status (needs Clink's
--                     cmd.get_errorlevel, on by default)
--   OSC 2             the folder as the title (title feature)
--   OSC 9;9           the working directory
--   OSC 133;P and I   around the prompt, the input running to the end of
--                     the line. P, not A: A's fresh-line would move
--                     Ghostty's cursor without ConPTY's. I, not B: ConPTY
--                     repaints rows with line feeds, which after B would
--                     mark output as input.
-- and OSC 133;C when a command line is accepted. Clink puts these around
-- the prompt's last line only, so of a prompt over several lines only the
-- last is marked (the lines above it count as the last command's output).

-- murrtty, the Windows fork, sets its own name.
local program = os.getenv("TERM_PROGRAM")
if program ~= "ghostty" and program ~= "murrtty" then return end

local ST = "\027\\"

-- Clink before 1.4.25 takes any OSC in a prompt whose number starts with
-- 0 to 2 as a title, so the 133 codes in cmd's prompt would blank the title
-- at every prompt. Those versions get the codes taken out, nothing more.
if (clink.version_encoded or 0) < 10040025 then
    if clink.promptfilter then
        local old = clink.promptfilter(-10000)
        function old:filter(prompt)
            return (prompt:gsub("\027%]133;[^\027]*\027\\", ""))
        end
    end
    return
end

local features = "," .. (os.getenv("GHOSTTY_SHELL_FEATURES") or "") .. ","
local title = features:find(",title[,:]") ~= nil
local command_ran = false

-- First, before other filters: the prompt as cmd made it.
local filter = clink.promptfilter(-10000)

function filter:filter(prompt)
    -- What PROMPT added: a block at the start ending with 133;P, and 133;I
    -- at the end.
    prompt = prompt:gsub("^\027%]133;D\027\\.-\027%]133;P;k=i\027\\", "", 1)
    prompt = prompt:gsub("\027%]133;I\027\\$", "", 1)
    return prompt
end

-- Clink expands cmd's $ codes in what this returns, so the directory goes
-- in as $P: a folder named with a $ (C:\$Recycle.Bin) stays as it is.
function filter:surround()
    local prefix = ""
    if command_ran then
        local status = ""
        if settings.get("cmd.get_errorlevel") then
            status = ";" .. os.geterrorlevel()
        end
        prefix = "\027]133;D" .. status .. ST
    end
    if title then prefix = prefix .. "\027]2;$P" .. ST end
    prefix = prefix .. "\027]9;9;$P" .. ST .. "\027]133;P;k=i" .. ST
    return prefix, "\027]133;I" .. ST
end

clink.onendedit(function(line)
    command_ran = line:find("%S") ~= nil
    if command_ran then clink.print("\027]133;C" .. ST, NONL) end
end)
