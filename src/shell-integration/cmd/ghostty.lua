-- Ghostty shell integration for cmd with Clink
-- (https://chrisant996.github.io/clink/), v1.4.24 or later. Ghostty adds
-- this folder to %CLINK_PATH% when it starts cmd, so Clink loads it.
--
-- The PROMPT Ghostty gives cmd reports each prompt, but can't report the
-- exit status, and a Clink prompt (a custom one in particular) may replace
-- it. So this script takes Ghostty's codes out of cmd's prompt and sends
-- them around whatever prompt Clink shows (its last line):
--   OSC 133;D;status  the last command's exit status (needs Clink's
--                     cmd.get_errorlevel, on by default)
--   OSC 2             the folder as the title (title feature)
--   OSC 9;9           the working directory
--   OSC 133;P and I   around the prompt, the input running to the end of
--                     the line. P, not A: A's fresh-line would move
--                     Ghostty's cursor without ConPTY's. I, not B: ConPTY
--                     repaints rows with line feeds, which after B would
--                     mark output as input.
-- and OSC 133;C when a command line is accepted.

if os.getenv("TERM_PROGRAM") ~= "ghostty" then return end
if (clink.version_encoded or 0) < 10040024 then return end

local ST = "\027\\"
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

function filter:surround()
    local cwd = os.getcwd()
    local prefix = ""
    if command_ran then
        local status = ""
        if settings.get("cmd.get_errorlevel") then
            status = ";" .. os.geterrorlevel()
        end
        prefix = "\027]133;D" .. status .. ST
    end
    if title then prefix = prefix .. "\027]2;" .. cwd .. ST end
    prefix = prefix .. "\027]9;9;" .. cwd .. ST .. "\027]133;P;k=i" .. ST
    return prefix, "\027]133;I" .. ST
end

clink.onendedit(function(line)
    command_ran = line:find("%S") ~= nil
    if command_ran then clink.print("\027]133;C" .. ST, NONL) end
end)
