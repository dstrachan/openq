# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenQ is an open-source implementation of the q programming language written in Zig. It provides a community-driven alternative to the proprietary q solution, focusing on supporting common idioms and widely-used functionality rather than exact replication.

## Build Commands

OpenQ uses Zig's build system. Common commands:

- `zig build` - Build the library and executable
- `zig build run` - Build and run the executable
- `zig build test` - Run all unit tests (both library and executable tests)
- `zig build run -- <command> [args]` - Run specific OpenQ commands

### OpenQ Commands

The main executable supports these commands:
- `openq tokenize [file]` - Tokenize q source code
- `openq parse [file]` - Parse q source code into AST  
- `openq validate [file]` - Validate q source code (parse + compile to QIR)
- `openq repl` - Start interactive REPL
- `openq help` - Show help
- `openq version` - Show version

## Architecture

### Core Components

The codebase is organized into several key modules in `src/q/`:

**Compilation Pipeline:**
- `tokenizer.zig` - Lexical analysis (Token, Tokenizer)
- `Parse.zig` - Parser that generates Abstract Syntax Tree (AST)
- `Ast.zig` - AST representation with nodes, tokens, and error handling
- `AstGen.zig` - AST to QIR (Q Intermediate Representation) compiler
- `Qir.zig` - Intermediate representation with instructions and metadata

**Runtime:**
- `Vm.zig` - Virtual machine that interprets QIR instructions
- `Value.zig` - Q value types (nil, lists, numbers, symbols, etc.)
- `Chunk.zig` - Bytecode chunks with opcodes

**VM Operations:**
The `vm/` directory contains individual operation implementations:
- Arithmetic: `add.zig`, `subtract.zig`, `multiply.zig`, `divide.zig`
- Unary: `negate.zig`, `reciprocal.zig`, `not.zig`
- List operations: `enlist.zig`, `first.zig`, `flip.zig`, `concat.zig`
- Other: `apply.zig`, `match.zig`, `type.zig`

### Data Flow

1. **Source** → **Tokenizer** → **Parser** → **AST**
2. **AST** → **AstGen** → **QIR** (Q Intermediate Representation)
3. **QIR** → **VM** → **Execution**

### Key Files

- `src/main.zig` - CLI interface and command implementations
- `src/root.zig` - Main module that exports all q components
- `src/utils.zig` - Utility functions for error formatting
- `build.zig` - Build configuration with version handling

## Build Configuration

The project supports debug builds with additional options:
- `trace_execution` - Enabled in Debug mode
- `print_code` - Enabled in Debug mode
- Custom version strings via `-Dversion-string`

## Testing

Tests are embedded in source files using Zig's built-in test framework. The build system runs both library and executable tests via `zig build test`.

## Memory Management

The VM uses a stack-based architecture with a maximum stack size of 256 values. Memory management follows Zig patterns with explicit allocator passing and proper cleanup in deinit functions.