--- subprocess: A Lua module for running commands as subprocesses
--- Similar to Python's subprocess module, using luaposix for process control

local posix = require("posix")
local subprocess = {}

-- Check if debug mode is enabled
local DEBUG = os.getenv("SUBPROCESS_DEBUG") == "1"

--- Print debug message if debug mode is enabled
local function debug_log(...)
    if DEBUG then
        io.stderr:write("[subprocess] ")
        io.stderr:write(...)
        io.stderr:write("\n")
        io.stderr:flush()
    end
end

--- Close pipe(s) by name or all if no name given
--- @param pipes table the pipes table
--- @param pipe_name string|nil name of pipe to close, or nil to close all
local function close_pipes(pipes, pipe_name)
    if pipe_name then
        local fd = pipes[pipe_name]
        if fd then
            debug_log("Closing pipe: ", pipe_name, ", fd=", fd)
            posix.close(fd)
            pipes[pipe_name] = nil
        else
            debug_log("No such pipe: ", pipe_name)
        end
    else
        debug_log("Closing all pipes")
        for name, fd in pairs(pipes) do
            if fd then
                debug_log("Closing pipe: ", name, ", fd=", fd)
                posix.close(fd)
                pipes[name] = nil
            end
        end
        debug_log("Closed all pipes")
    end
end

--- Create all pipes (stdin, stdout, stderr, and exec_error for reporting execp failures)
--- @return table|nil pipes table with stdin_r, stdin_w, stdout_r, stdout_w, stderr_r, stderr_w, exec_error_r, exec_error_w or nil on error
--- @return string|nil error message if creation failed
local function create_pipes()
    debug_log("Creating pipes")
    local pipes = {}

    local stdin_r, stdin_w = posix.pipe()
    if not stdin_r then
        close_pipes(pipes)
        return nil, "Failed to create stdin pipe: " .. stdin_w
    end
    pipes.stdin_r = stdin_r
    pipes.stdin_w = stdin_w
    posix.fcntl(stdin_w, posix.F_SETFL, posix.O_NONBLOCK)
    posix.fcntl(stdin_w, posix.F_SETFD, posix.FD_CLOEXEC)
    debug_log("Created stdin pipe: r=", stdin_r, " w=", stdin_w)

    local stdout_r, stdout_w = posix.pipe()
    if not stdout_r then
        close_pipes(pipes)
        return nil, "Failed to create stdout pipe: " .. stdout_w
    end
    pipes.stdout_r = stdout_r
    pipes.stdout_w = stdout_w
    posix.fcntl(stdout_r, posix.F_SETFL, posix.O_NONBLOCK)
    posix.fcntl(stdout_r, posix.F_SETFD, posix.FD_CLOEXEC)
    debug_log("Created stdout pipe: r=", stdout_r, " w=", stdout_w)

    local stderr_r, stderr_w = posix.pipe()
    if not stderr_r then
        close_pipes(pipes)
        return nil, "Failed to create stderr pipe: " .. stderr_w
    end
    pipes.stderr_r = stderr_r
    pipes.stderr_w = stderr_w
    posix.fcntl(stderr_r, posix.F_SETFL, posix.O_NONBLOCK)
    posix.fcntl(stderr_r, posix.F_SETFD, posix.FD_CLOEXEC)
    debug_log("Created stderr pipe: r=", stderr_r, " w=", stderr_w)

    local exec_error_r, exec_error_w = posix.pipe()
    if not exec_error_r then
        close_pipes(pipes)
        return nil, "Failed to create exec_error pipe: " .. exec_error_w
    end
    pipes.exec_error_r = exec_error_r
    pipes.exec_error_w = exec_error_w
    posix.fcntl(exec_error_w, posix.F_SETFD, posix.FD_CLOEXEC)
    debug_log("Created exec_error pipe: r=", exec_error_r, " w=", exec_error_w)

    debug_log("All pipes created successfully")
    return pipes, nil
end

--- Read as much data as possible from a pipe
--- @param pipes table pipe file descriptors
--- @param name string name of the pipe to read from
--- @return string|nil read data or nil on error
--- @return string|nil error message if read failed
local function read_all(pipes, name)
    local data = ""

    while true do
        local chunk, err, err_code = posix.read(pipes[name], 4096)
        if not chunk then
            if err_code == posix.EAGAIN or err_code == posix.EWOULDBLOCK then
                debug_log("read_all: ", name, " would block")
                break
            else
                debug_log("read_all: reading from ", name, " failed: ", err)
                return nil, err
            end
        elseif #chunk > 0 then
            data = data .. chunk
            debug_log("read_all: read ", #chunk, " bytes from ", name)
        else
            debug_log("read_all: no more data to read from ", name)
            close_pipes(pipes, name)
            break
        end
    end

    return data, nil
end

--- Write as much data as possible to a pipe
--- @param pipes table pipe file descriptors
--- @param name string name of the pipe to write to
--- @param data table input data state {data=string, pos=number}
--- @return integer|nil number of data bytes written or nil on error
--- @return string|nil error message if write failed
local function write_all(pipes, name, data)
    local total_written = 0

    while true do
        if data.pos >= #data.data then
            debug_log("write_all: all data written, closing ", name)
            close_pipes(pipes, name)
            break
        end

        local nbytes = #data.data - data.pos

        -- Handle broken pipe gracefully
        local prev_handler = posix.signal(posix.SIGPIPE, posix.SIG_IGN)
        local written, err, err_code = posix.write(pipes.stdin_w, data.data, nbytes, data.pos)
        posix.signal(posix.SIGPIPE, prev_handler)

        if not written then
            if err_code == posix.EAGAIN or err_code == posix.EWOULDBLOCK then
                debug_log("write_all: ", name, " would block")
                break
            elseif err_code == posix.EPIPE then
                debug_log("write_all: broken pipe, closing ", name)
                close_pipes(pipes, name)
                break
            else
                debug_log("write_all: writing to ", name, " failed: ", err)
                return nil, err
            end
        else
            data.pos = data.pos + written
            total_written = total_written + written
            debug_log("write_all: wrote ", written, " bytes to stdin")
        end
    end

    return total_written, nil
end

--- Poll for I/O events and handle reading/writing
--- @param pipes table pipe file descriptors
--- @param data table input data state {data=string, pos=number}
--- @param result table result table to populate
--- @return boolean|nil true if pipes remain, false if all closed, nil on error
--- @return string|nil error message if operation failed
local function poll_and_read_write(pipes, data, result)
    -- Setup poll file descriptors table
    local fds = {}
    if pipes.stdin_w then
        fds[pipes.stdin_w] = {events = {OUT = true}}
    end
    if pipes.stdout_r then
        fds[pipes.stdout_r] = {events = {IN = true}}
    end
    if pipes.stderr_r then
        fds[pipes.stderr_r] = {events = {IN = true}}
    end

    -- Return false if no pipes left open
    if not next(fds) then
        debug_log("poll_and_read_write: no pipes to poll")
        return false, nil
    end

    -- Avoid table operations if debugging is off
    if DEBUG then
        local fd_list = {}
        for fd, _ in pairs(fds) do
            table.insert(fd_list, fd)
        end
        debug_log("poll_and_read_write: polling fds=[", table.concat(fd_list, ", "), "]")
    end

    local nfds, err = posix.poll.poll(fds)

    if not nfds then
        debug_log("poll_and_read_write: poll failed: ", err)
        return nil, err
    end

    debug_log("poll_and_read_write: poll returned ", nfds, " events")

    for fd, fd_info in pairs(fds) do
        local revents = fd_info.revents or {}
        local chunk, written

        if fd == pipes.stdin_w and (revents.OUT or revents.ERR) then
            debug_log("poll_and_read_write: writing to stdin (pos=", data.pos, "/", #data.data, ")")
            written, err = write_all(pipes, "stdin_w", data)
            if not written then
                return nil, err
            end
        end

        if fd == pipes.stdout_r and (revents.IN or revents.HUP) then
            debug_log("poll_and_read_write: reading from stdout")
            chunk, err = read_all(pipes, "stdout_r")
            if chunk then
                result.stdout_data = result.stdout_data .. chunk
            else
                return nil, err
            end
        end

        if fd == pipes.stderr_r and (revents.IN or revents.HUP) then
            debug_log("poll_and_read_write: reading from stderr")
            chunk, err = read_all(pipes, "stderr_r")
            if chunk then
                result.stderr_data = result.stderr_data .. chunk
            else
                return nil, err
            end
        end
    end

    return true, nil
end

--- Child process logic after fork
--- @param cmd string the command to execute
--- @param args table command arguments
--- @param pipes table pipe file descriptors
local function child_process(cmd, args, pipes)
    debug_log("Child process: redirecting file descriptors")
    -- Redirect file descriptors
    posix.dup2(pipes.stdin_r, posix.fileno(io.stdin))
    posix.dup2(pipes.stdout_w, posix.fileno(io.stdout))
    posix.dup2(pipes.stderr_w, posix.fileno(io.stderr))

    close_pipes(pipes, "stdin_r")
    close_pipes(pipes, "stdout_w")
    close_pipes(pipes, "stderr_w")
    close_pipes(pipes, "exec_error_r")

    -- Execute the command with arguments
    debug_log("Child process: executing ", cmd)
    local _, err = posix.execp(cmd, args)
    -- If execp returns, it failed - write error to pipe and exit
    debug_log("Child process: execp failed: ", err)
    posix.write(pipes.exec_error_w, err)
    os.exit(127)
end

--- Parent process logic after fork
--- @param pid number child process ID
--- @param pipes table pipe file descriptors
--- @param input_data string data to write to stdin
--- @return table|nil result table or nil on error
--- @return string|nil error message
local function parent_process(pid, pipes, input_data)
    debug_log("Parent process: child PID=", pid)
    -- Close parent-irrelevant pipe ends
    close_pipes(pipes, "stdin_r")
    close_pipes(pipes, "stdout_w")
    close_pipes(pipes, "stderr_w")
    close_pipes(pipes, "exec_error_w")

    local err
    local result = {stdout_data = "", stderr_data = "", exit_status = nil}

    -- Check for exec errors early (before initializing result fields)
    local exec_err = posix.read(pipes.exec_error_r, 1024)
    if #exec_err > 0 then
        debug_log("Parent process: child exec failed: ", exec_err)
        err = "Failed to execute: " .. exec_err
        close_pipes(pipes, "exec_error_r")
        goto wait_child
    end
    close_pipes(pipes, "exec_error_r")

    debug_log("Parent process: child exec succeeded, starting I/O loop")
    do
        -- Track input data for writing
        local data = {data = input_data, pos = 0}

        while true do
            -- Poll and handle I/O
            local left, io_err = poll_and_read_write(pipes, data, result)
            if left == nil then
                debug_log("Parent process: I/O failed: ", io_err)
                debug_log("Parent process: killing child")
                posix.kill(pid, posix.SIGTERM)
                err = "I/O error: " .. io_err
                break
            elseif not left then
                debug_log("Parent process: no more pipes, exiting I/O loop")
                break
            end
        end
    end

    ::wait_child::
    debug_log("Parent process: waiting for child to exit")
    local wpid, status, ret = posix.wait(pid)
    debug_log("Parent process: wpid=", wpid, ", status=", status, ", ret=", ret)

    if wpid == pid then
        -- Extract exit status
        if status == "exited" then
            result.exit_status = ret
            debug_log("Parent process: child exited with status ", ret)
        elseif status == "killed" then
            result.exit_status = 128 + ret
            debug_log("Parent process: child killed by signal ", ret)
        end
    end

    if err then
        return nil, err
    else
        return result, nil
    end
end

--- Run a command as a subprocess with optional input data
--- @param cmd string The command to execute (path or command name)
--- @param args table|nil Command arguments as a table (e.g., {"arg1", "arg2"})
--- @param input_data string|nil Data to pipe into stdin
--- @return table|nil Result table with fields:
---   - stdout_data: string captured from stdout (or nil on error)
---   - stderr_data: string captured from stderr (or nil on error)
---   - exit_status: integer exit code
---   or nil on subprocess error
--- @return string|nil Error message
function subprocess.run(cmd, args, input_data)
    -- Validate arguments
    if not cmd then
        return nil, "Command is required"
    end

    args = args or {}
    if DEBUG then
        local args_str = table.concat(args, ", ")
        debug_log("subprocess.run called: cmd=", cmd, " args=[", args_str, "]")
    end

    input_data = input_data or ""

    -- Create pipes for stdin, stdout, stderr
    local pipes, err = create_pipes()
    if not pipes then
        return nil, err
    end

    local result

    -- Fork the process
    local pid, fork_err = posix.fork()
    if not pid then
        debug_log("Fork failed: ", fork_err)
        err = "Failed to fork process: " .. fork_err
        goto cleanup
    end

    debug_log("Process forked: pid=", pid)
    if pid == 0 then
        child_process(cmd, args, pipes)
    else
        result, err = parent_process(pid, pipes, input_data)
    end

    ::cleanup::
    close_pipes(pipes)

    if err then
        return nil, err
    else
        return result, nil
    end
end

return subprocess
