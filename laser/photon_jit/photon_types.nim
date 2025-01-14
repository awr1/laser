# Laser
# Copyright (c) 2018 Mamy André-Ratsimbazafy
# Distributed under the Apache v2 License (license terms are at http://www.apache.org/licenses/LICENSE-2.0).
# This file may not be copied, modified, or distributed except according to those terms.

import
  ../private/align_unroller,
  ./photon_osalloc,
  hashes, tables, macros, random

type
  JitFunction* = ref object
    adr:     pointer
    len:     int

  Label* = object
    ## Label for a jump or effective addressing opcodes
    ## Always initialise a label with the `label()` proc
    id: int
  ByteCode* = seq[byte]
  CodePos* = int

  LabelInfo* = object
    pos:   int          # Label target
    useAt: seq[CodePos] # Bytecode to rewrite with the label target

  Assembler*[Arch] = object
    code*: ByteCode                  # Generated bytecode
    labels*: Table[Label, LabelInfo] # Bytecode to rewrite with the actual label location
    # Determined at compile-time
    clean_regs*: bool
    restore_regs*: ByteCode          # Return opcodes must restore clobbered registers
      # Even though clean_regs and code_restore_regs are known at compile-time
      # We still use a runtime bool and a seq to avoid inflating the binary size
      #   - with one instantiation for autoclean and raw assembly
      #   - and with one instantiation of each opcode per clobbered registers

  DirtyRegs*[R: enum] = object
    # We determine at compile-time all registers that are potentially
    # touched by the codegen. We might uselessly save/restore registers
    # if different code branches touch different registers.
    # However finely tracking used registers at runtime would probably be costlier.
    clobbered_regs*: set[R]     # Dirty registers that need to be saved/restored
    save_regs*: ByteCode        # Bytecode to save registers upon function entry
    restore_regs*: ByteCode     # Bytecode to restore registers before all return opcodes.

# ############################################################
#
#                  JitFunction routines
#
# ############################################################

proc deallocJitFunction(fn: JitFunction) =
  if not fn.adr.isNil:
    munmap(fn.adr, fn.len)

proc allocJitFunction(min_size: Positive): JitFunction {.sideeffect.} =
  new result, deallocJitFunction
  result.len = round_step_up(min_size, PageSize)
  result.adr = mmap(
                  nil, result.len,
                  static(flag(ProtRead, ProtWrite)),
                  static(flag(MapAnonymous, MapPrivate)),
                  -1, 0
                )
  doAssert cast[int](result.adr) != -1, "JitFunction allocation failure"

proc newJitFunction*[R](a: Assembler[R]): JitFunction =
  # Each code fragment is allocated to it's own page(s)
  # This probably waste a lot of space (4096-bit)
  # but this allows mprotect granularity, as it's page-wide
  result = allocJitFunction(a.code.len)
  copyMem(result.adr, a.code[0].unsafeAddr, a.code.len)
  mprotect(result.adr, result.len, flag(ProtRead, ProtExec))

proc call*(fn: JitFunction) {.inline, sideeffect.} =
  let f = cast[proc(){.nimcall.}](fn.adr)
  f()

# ############################################################
#
#               Clobbered registers routines
#
# ############################################################

proc searchClobberedRegs*[R: enum](dr: var DirtyRegs[R], ast: NimNode) =
  ## Warnings:
  ##   - this does not resolve aliases
  ##     i.e. const foobar = rax
  ##   - if you call anything `rax` in the AST, even a proc
  ##     `rax` will be added to the clobbered list.
  proc inspect(s: var set[R], node: NimNode) =
    case node.kind:
    of {nnkIdent, nnkSym}:
      for reg in R:
        if node.eqIdent($reg):
          s.incl reg
    of nnkEmpty:
      discard
    of nnkLiterals:
      discard
    else:
      for child in node:
        s.inspect(child)
  dr.clobbered_regs.inspect(ast)

# ############################################################
#
#            Jump/Effective Address routines
#
# ############################################################

var label_rng = initRand(0x1337DEADBEEF)

proc initLabel*(): Label =
  ## Create a new unique label.
  ## Label IDs are assigned at runtime and are unique
  ## even in loops like
  ## ```
  ## for _ in 0 ..< 10:
  ##   let L1 = initLabel()
  ## ```
  result.id = label_rng.rand(high(int))

template hash*(l: Label): Hash =
  Hash(l.id)

func label*(a: var Assembler, l: Label) {.inline.}=
  ## Mark the current location with a label
  ## to set it as a jump or load effective address target
  a.labels.mgetOrPut(l, LabelInfo()).pos = a.code.len

func add_target*(a: var Assembler, l: Label) {.inline.}=
  ## Add a target label at the current code
  ## 4-byte placeholder should be left to
  ## be overwritten during post-processing
  ## This proc should be called just after the placeholder bytes
  a.labels.mgetOrPut(l, LabelInfo()).use_at.add a.code.len

func post_process*(a: var Assembler) =
  ## Once we parsed and generated most of the code
  ## we need to backtrack and write the labels target

  for labelInfo in a.labels.values:
    for useAt in labelInfo.useAt:
      a.code[useAt-4 ..< useAt] = cast[array[4, byte]](
        uint32 labelInfo.pos - useAt
      )

# ############################################################
#
#    Notes on labels, displacements and jump targets
#
# ############################################################

# We always use 32-bit displacement but
# for jumps and SIB addressing (but not RIP relative),
# there are 8-bit displacement versions.
# While those save on code size it complexifies codegen
# as we can't use 4-byte placeholders anymore, or if we use those
# we would need to delete the next 3-byte:
#   - either by physically overwriting it in the buffer
#     with data coming next
#   - or by not copying it in the executable mmap memory
#     while today we have a convenient and fast memcpy.
#   - and all subsequent label targets must be offset by cumulative 3 bytes.
# In summary the gain on codesize and by using the
# CPU instruction cache more effectively will probably
# be completely obliterated by the JIT codegen overhead
# if machine code is JIT generated regularly.

# In machine learning, numerical computing and image processing context
# most of the time is spent either waiting on memory bandwidth or
# in Fused-Multiply-Add kernels, 8-bit vs 32-bit jumps are irrelevant.

# For interpreters, we can reasonable expect to spend a lot of time
# doing control flow in the generated JIT code and so using smaller jumps might
# be worthwhile. i.e. TODO with a opt_label_size static bool switch.

# ############################################################
#
#            Notes on caching mechanisms
#
# ############################################################

# This is a hard problem, with 2 potential rewards:
#    1. Saving on memory allocation for the JIT code
#    2. Reducing CPU overhead by avoiding unnecessary compilation.

# However:
#    1. A caller/user has more context for its usecase
#       and could pass the JitFunction around once it's compiled once.
#       Even if the caller is another library, caching at the higher-level library
#       probably makes most sense.

#    2. As we go through the dynamic code generation we keep a hash of
#       the bytecode generated. Finally if the hash already exists in the code cache
#       we can just not copy the bytecode and reuse the mmap region containing the
#       same bytecode.
#       ----
#       This reduces unnecessary memory allocation and saves a copy,
#       but we still incur compilation overhead + hashing added on top.
#       ----
#       Hashing the AST in one pass and geneating the bytecode in another
#       (instead of just hashing the bytecode) will render the codegen quadratic
#       + we also need to define a runtime AST.

#    3. Alternatively, we could use the compile-time AST and derive a cache key from it
#       with 2 different alternatives:
#         A1. Parsing the Nim AST tree and computing a base hash at compile-time
#             There is a need to detect the runtime immediates and
#             add their runtime values to the hash.
#         A2. Alternatively each proc will do the following pseudocode
#             ```
#             proc mov(a: static Assembler, reg: static Register, imm32: uint32) =
#               const opcode = byte(0xB8 + reg.byte)

#               block:                      # Compile-time part
#                 a.hash = a.hash !& opcode
#                 a.hash = a.hash !& 0      # Placeholder hashing as immediate is nly known at runtime
#                 a.immediates.add imm32    # Add the immediate sym/ident to a seq[NimNode]
#                 a.clobbered_regs.add reg

#               block:                      # Run-time part
#                 a.code.add opcode
#                 a.code.add cast[array[4, byte]](imm32)
#             ```
#             And we can finalise the compile-time hash at runtime
#             with the seq[NimNode] of immediates.
#         ------------
#         Pros & Cons:
#           A1. The runtime cost is minimal, however separating the immediate symbols
#               from procs, temporaries, enums symbols seems tricky.
#           A2. There is one challenge to have a compile-time and run-time part
#               for "Assembler", this probably requires macro everywhere of procs
#               which is trivial.
#               Separating run-time immediates from the rest of symbols is easy
#               However this cannot deal easily with runtime branching in codegen:
#               ```
#               if runtime_bool:
#                 a.mov(rax, 1)
#               else:
#                 a.mov(rbx, 2)
#               ```
#               1. Both branches will participate in the base compile-time hash
#                  meaning even if there is already a `a.mov(rax, 1)` fragment in
#                  the code cache, a code with branching will still generate its own.
#                  That's an OK price.
#               2. `runtime_bool` needs to contribute to the final hash as well
#                  - Easiest would be asking the caller which runtime symbols
#                    participate in control flow. Caveat with non-determinstic proc below.
#                  - Alternatively, a static analysis that determines all
#                    runtime values that participate in control flow.
#                    Nim runtime control structures are:
#                      - `if`, `case`, `for`, `while`, `break`
#                    Hashing values known at compile-time is not an issue.
#                    The tricky part are mutable vars and non-deterministic procs,
#                    for example in a while loop:
#                    ```
#                    var i = 0
#                    while i < foo.len:
#                      a.mov(rax, 1)
#                      inc i
#                    ```
#                    ---> we need to hash `foo.len` but not `i`
#                    ```
#                    while foo.len > 0:
#                      a.mov(rax, foo.pop())
#                    ```
#                    ---> we need to hash `foo` but not `foo.len`
#                    ```
#                    while nondeterministic(foo) > 0:
#                      a.mov(rax, 1)
#                    ```
#                    ---> no solution, each call to nondeterminstic(foo)
#                         must be hashed

# Note that this caching problem is the same problem as
#   - static computation graph (define-and-run) like Tensorflow
#   - dynamic computation graph (define-by-run) like PyTorch
# in deep learning with the same tradeoffs:
#   - With static graphs you need a DSL to deal with control flow, i.e. inflexibility.
#   - with dynamic graphs you need to generate the graph repeatedly and cannot cache it.
