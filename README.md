# lua-subprocess-posix

A Lua module for running commands as subprocesses, similar to Python's `subprocess` module. Built on `luaposix` for cross-platform POSIX process control.

## Features

- **Simple API**: Run commands with arguments and capture stdout/stderr
- **Input/Output Handling**: Pipe input data to subprocesses and capture their output
- **Exit Status**: Access the exit code of executed commands
- **Error Handling**: Comprehensive error reporting for failures
- **Binary Safe**: Handles binary data and special characters correctly
- **Large Data**: Efficiently handles large inputs/outputs without buffering limits
- **Broken Pipe Handling**: Gracefully handles pipes that break due to processes exiting
- **Debug Mode**: Enable detailed logging by setting the environment variable `SUBPROCESS_DEBUG=1`

## Requirements

- Lua 5.4
- [luaposix](https://github.com/luaposix/luaposix) - POSIX API bindings for Lua

## Installation

### Prerequisites

Install `luaposix` using your system's package manager:

```bash
# Ubuntu/Debian
sudo apt-get install lua-posix

# Install using luarocks
luarocks install luaposix

# Or build from source
git clone https://github.com/luaposix/luaposix.git
cd luaposix
./build-aux/luke
```

### Setup

1. Clone or download this repository:
```bash
git clone https://github.com/hubertwisniewski0/lua-subprocess-posix.git
cd lua-subprocess-posix
```

2. Place `src/subprocess.lua` in your Lua module search path:
   - Copy to your Lua modules directory (e.g., `/usr/local/lib/lua/5.4/` or `./`)
   - Or ensure the directory is in your `LUA_PATH` environment variable

3. Verify installation:
```lua
local subprocess = require("subprocess")
print("subprocess module loaded successfully")
```

## Usage

### Basic Example

```lua
local subprocess = require("subprocess")

-- Run a simple command
local result, err = subprocess.run("echo", {"hello", "world"})
if err then
    print("Error:", err)
else
    print("Output:", result.stdout_data)
    print("Exit code:", result.exit_status)
end
```

### Running Commands with Input

```lua
local subprocess = require("subprocess")

-- Pipe data into stdin
local result, err = subprocess.run("tr", {"[:lower:]", "[:upper:]"}, "hello world")
if not err then
    print(result.stdout_data)  -- Outputs: HELLO WORLD
end
```

### Capturing stderr

```lua
local subprocess = require("subprocess")

-- Capture both stdout and stderr
local result, err = subprocess.run("sh", {"-c", "echo output; echo error >&2"})
if not err then
    print("stdout:", result.stdout_data)
    print("stderr:", result.stderr_data)
    print("exit code:", result.exit_status)
end
```

### Handling Errors

```lua
local subprocess = require("subprocess")

-- Error handling for non-existent commands
local result, err = subprocess.run("nonexistent_command")
if err then
    print("error:", err)
end

-- Error handling for command failures
local result, err = subprocess.run("sh", {"-c", "exit 42"})
if not err then
    print("Exit code:", result.exit_status)  -- 42
end

-- Signal handing
-- If the child terminated because of a signal, the exit code is 128 + signal number
-- e.g. 128 + SIGTERM = 128 + 15 = 143
local result, err = subprocess.run("sh", {"-c", "kill -TERM $$"})
if not err then
    print("Exit code:", result.exit_status)  -- 143
end
```

### Passing 0-th argument

```lua
local subprocess = require("subprocess")

-- Make the shell think its name is "tomato"
local result, err = subprocess.run("sh", {[0] = "tomato", "-c", 'echo My name is \\"$0\\"'})
if not err then
    print("stdout:", result.stdout_data)  -- My name is "tomato"
    print("exit code:", result.exit_status)
end
```

## API Reference

### `subprocess.run(cmd, args, input_data)`

Executes a command as a subprocess and returns the result.

#### Parameters

- **`cmd`** (string, required): Command to execute (can be a path or command name)
- **`args`** (table, optional): Command arguments as a Lua table. 0-th argument can be set be set by assigning it to key 0:
  - Example: `{"arg1", "arg2", "arg3"}`
  - Example: `{[0] = "arg0", "arg1", "arg2", "arg3"}`
  - Default: empty table
- **`input_data`** (string, optional): Data to write to subprocess stdin
  - Default: empty string

#### Returns

On success:
- **`result`** (table): Table with the following fields:
  - `stdout_data` (string): Data captured from stdout
  - `stderr_data` (string): Data captured from stderr
  - `exit_status` (integer): Process exit code in shell convention: either the exit code or 128 + signal number if killed by signal
- **`err`** (nil): No error occurred

On failure:
- **`result`** (nil): Indicates an error occurred
- **`err`** (string): Error message describing the failure

## Debugging

Enable debug logging by setting the `SUBPROCESS_DEBUG` environment variable:

```bash
SUBPROCESS_DEBUG=1 lua your_script.lua
```

This will print detailed logging messages to stderr, including:
- Process creation and execution
- Pipe creation and file descriptor operations
- I/O polling and read/write operations
- Child process execution and errors

Example debug output:
```
[subprocess] [12345] loading subprocess
[subprocess] [12345] run: cmd=echo, args=[hello, world]
[subprocess] [12345] create_pipes: stdin r=3, w=4
[subprocess] [12345] poll_and_read_write: reading from stdout
[subprocess] [12345] read_all: read 6 bytes from stdout_r
```

## Limitations

### Race Conditions in Multithreaded Programs

This Lua implementation uses `posix.pipe()` followed by `posix.fcntl()` to set the `FD_CLOEXEC` flag. In multithreaded programs, this creates a race condition where a child process may inherit the parent's pipe file descriptors intended for other children.

**Workaround**: The recommended solution is to use `pipe2()` with `O_CLOEXEC` flag atomically, which unfortunately is not possible with the current version of luaposix (36.3 at the time of writing this).

## Testing

Run the test suite using LuaUnit:

```bash
lua test/test_subprocess.lua
```

The test suite includes:
- Basic command execution
- Input/output handling
- Exit status verification
- Error handling and edge cases
- Large data and binary-safe operations
- Broken pipe handling

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests for improvements, bug fixes, or new features.

## Future Plans

- **C-based rewrite**: Improve performance and eliminate pipe race conditions using atomic `pipe2()` operations
- **Process timeouts**: Add configurable timeout support
- **Multiple output pipes**: Support for capturing additional process output streams
- **Asynchronous execution**: Running processes in the background and talking to them interactively

## Related Projects

- [luaposix](https://github.com/luaposix/luaposix) - POSIX API bindings for Lua
- [Python subprocess](https://docs.python.org/3/library/subprocess.html) - The inspiration for this module's API
