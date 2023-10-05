#
#
#           The Nim Compiler
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [assertions, tables, sets]
import ".." / [ast, astalgo, types, options, lineinfos, msgs, magicsys,
  modulegraphs, guards, renderer]
from ".." / lowerings import lowerSwap
from ".." / pathutils import customPath
import .. / ic / bitabs

import nirtypes, nirinsts, nirlineinfos, nirslots, types2ir

type
  ModuleCon = ref object
    strings: BiTable[string]
    integers: BiTable[int64]
    man: LineInfoManager
    types: TypesCon
    slotGenerator: ref int
    module: PSym
    graph: ModuleGraph
    nativeIntId: TypeId
    idgen: IdGenerator
    pendingProcs: Table[ItemId, PSym] # procs we still need to generate code for

  LocInfo = object
    inUse: bool
    typ: TypeId

  ProcCon = object
    config: ConfigRef
    lastFileKey: FileIndex
    lastFileVal: LitId
    labelGen: int
    exitLabel: LabelId
    code: Tree
    blocks: seq[(PSym, LabelId)]
    sm: SlotManager
    locGen: int
    m: ModuleCon
    prc: PSym

proc initModuleCon*(graph: ModuleGraph; config: ConfigRef; idgen: IdGenerator; module: PSym): ModuleCon =
  result = ModuleCon(graph: graph, types: initTypesCon(config), slotGenerator: new(int),
    idgen: idgen, module: module)
  case config.target.intSize
  of 2: result.nativeIntId = Int16Id
  of 4: result.nativeIntId = Int32Id
  else: result.nativeIntId = Int64Id

proc initProcCon*(m: ModuleCon; prc: PSym): ProcCon =
  ProcCon(m: m, sm: initSlotManager({}, m.slotGenerator), prc: prc)

proc toLineInfo(c: var ProcCon; i: TLineInfo): PackedLineInfo =
  var val: LitId
  if c.lastFileKey == i.fileIndex:
    val = c.lastFileVal
  else:
    val = c.m.strings.getOrIncl(toFullPath(c.config, i.fileIndex))
    # remember the entry:
    c.lastFileKey = i.fileIndex
    c.lastFileVal = val
  result = pack(c.m.man, val, int32 i.line, int32 i.col)

when false:
  proc gen*(c: var ProcCon; d: var Tree; n: PNode)
  proc genv*(c: var ProcCon; d: var Tree; v: var Value; n: PNode)

  proc genx*(c: var ProcCon; d: var Tree; n: PNode): SymId =
    let info = toLineInfo(c, n.info)
    let t = typeToIr(c.m.types, n.typ)
    result = allocTemp(c.sm, t)
    addSummon d, info, result, t
    var ex = localToValue(info, result)
    genv(c, d, ex, n)
  template withBlock(lab: LabelId; body: untyped) =
    body
    d.addInstr(info, Label, lab)

  proc genWhile(c: var ProcCon; d: var Tree; n: PNode) =
    # LoopLabel lab1:
    #   cond, tmp
    #   select cond
    #   of false: goto lab2
    #   body
    #   GotoLoop lab1
    # Label lab2:
    let info = toLineInfo(c, n.info)
    let loopLab = d.addLabel(c.labelGen, info, LoopLabel)
    let theEnd = newLabel(c.labelGen)
    withBlock(theEnd):
      if isTrue(n[0]):
        c.gen(d, n[1])
        d.gotoLabel info, GotoLoop, loopLab
      else:
        let x = c.genx(d, n[0])
        #d.addSelect toLineInfo(c, n[0].kind), x
        c.gen(d, n[1])
        d.gotoLabel info, GotoLoop, loopLab

  proc genv*(c: var ProcCon; d: var Tree; v: var Value; n: PNode) =
    quit "too implement"

  proc gen*(c: var ProcCon; d: var Tree; n: PNode) =
    case n.kind
    of nkWhileStmt:
      genWhile c, d, n
    else:
      discard

proc bestEffort(c: ProcCon): TLineInfo =
  if c.prc != nil:
    c.prc.info
  else:
    c.m.module.info

proc popBlock(c: var ProcCon; oldLen: int) =
  c.blocks.setLen(oldLen)

template withBlock(labl: PSym; info: PackedLineInfo; asmLabl: LabelId; body: untyped) {.dirty.} =
  var oldLen {.gensym.} = c.blocks.len
  c.blocks.add (labl, asmLabl)
  body
  popBlock(c, oldLen)

type
  GenFlag = enum
    gfAddrOf # load the address of the expression
    gfToOutParam # the expression is passed to an `out` parameter
  GenFlags = set[GenFlag]

proc gen(c: var ProcCon; n: PNode; d: var Value; flags: GenFlags = {})

proc genScope(c: var ProcCon; n: PNode; d: var Value; flags: GenFlags = {}) =
  openScope c.sm
  gen c, n, d, flags
  closeScope c.sm

proc freeTemp(c: var ProcCon; tmp: Value) =
  let s = extractTemp(tmp)
  if s != SymId(-1):
    freeTemp(c.sm, s)

proc getTemp(c: var ProcCon; n: PNode): Value =
  let info = toLineInfo(c, n.info)
  let t = typeToIr(c.m.types, n.typ)
  let tmp = allocTemp(c.sm, t)
  c.code.addSummon info, tmp, t
  result = localToValue(info, tmp)

template withTemp(tmp, n, body: untyped) {.dirty.} =
  var tmp = getTemp(c, n)
  body
  c.freeTemp(tmp)

proc gen(c: var ProcCon; n: PNode; flags: GenFlags = {}) =
  var tmp = default(Value)
  gen(c, n, tmp, flags)
  freeTemp c, tmp

proc genScope(c: var ProcCon; n: PNode; flags: GenFlags = {}) =
  openScope c.sm
  gen c, n, flags
  closeScope c.sm

proc genx(c: var ProcCon; n: PNode; flags: GenFlags = {}): Value =
  result = default(Value)
  gen(c, n, result, flags)

proc clearDest(c: var ProcCon; n: PNode; d: var Value) {.inline.} =
  when false:
    if n.typ.isNil or n.typ.kind == tyVoid:
      let s = extractTemp(d)
      if s != SymId(-1):
        freeLoc(c.sm, s)

proc isNotOpr(n: PNode): bool =
  n.kind in nkCallKinds and n[0].kind == nkSym and n[0].sym.magic == mNot

proc jmpBack(c: var ProcCon; n: PNode; lab: LabelId) =
  c.code.gotoLabel toLineInfo(c, n.info), GotoLoop, lab

type
  JmpKind = enum opcFJmp, opcTJmp

proc xjmp(c: var ProcCon; n: PNode; jk: JmpKind; v: Value): LabelId =
  result = newLabel(c.labelGen)
  let info = toLineInfo(c, n.info)
  build c.code, info, Select:
    c.code.addTyped info, Bool8Id
    c.code.copyTree Tree(v)
    build c.code, info, SelectPair:
      build c.code, info, SelectValue:
        c.code.boolVal(info, jk == opcTJmp)
      c.code.gotoLabel info, Goto, result

proc patch(c: var ProcCon; n: PNode; L: LabelId) =
  addLabel c.code, toLineInfo(c, n.info), Label, L

proc genWhile(c: var ProcCon; n: PNode) =
  # lab1:
  #   cond, tmp
  #   fjmp tmp, lab2
  #   body
  #   jmp lab1
  # lab2:
  let info = toLineInfo(c, n.info)
  let lab1 = c.code.addNewLabel(c.labelGen, info, LoopLabel)
  withBlock(nil, info, lab1):
    if isTrue(n[0]):
      c.gen(n[1])
      c.jmpBack(n, lab1)
    elif isNotOpr(n[0]):
      var tmp = c.genx(n[0][1])
      let lab2 = c.xjmp(n, opcTJmp, tmp)
      c.freeTemp(tmp)
      c.gen(n[1])
      c.jmpBack(n, lab1)
      c.patch(n, lab2)
    else:
      var tmp = c.genx(n[0])
      let lab2 = c.xjmp(n, opcFJmp, tmp)
      c.freeTemp(tmp)
      c.gen(n[1])
      c.jmpBack(n, lab1)
      c.patch(n, lab2)

proc genBlock(c: var ProcCon; n: PNode; d: var Value) =
  openScope c.sm
  let info = toLineInfo(c, n.info)
  let lab1 = newLabel(c.labelGen)

  withBlock(n[0].sym, info, lab1):
    c.gen(n[1], d)

  c.code.addLabel(info, Label, lab1)
  closeScope c.sm
  c.clearDest(n, d)

proc jumpTo(c: var ProcCon; n: PNode; L: LabelId) =
  c.code.addLabel(toLineInfo(c, n.info), Goto, L)

proc genBreak(c: var ProcCon; n: PNode) =
  if n[0].kind == nkSym:
    for i in countdown(c.blocks.len-1, 0):
      if c.blocks[i][0] == n[0].sym:
        c.jumpTo n, c.blocks[i][1]
        return
    localError(c.config, n.info, "NIR problem: cannot find 'break' target")
  else:
    c.jumpTo n, c.blocks[c.blocks.high][1]

proc genIf(c: var ProcCon; n: PNode; d: var Value) =
  #  if (!expr1) goto lab1;
  #    thenPart
  #    goto LEnd
  #  lab1:
  #  if (!expr2) goto lab2;
  #    thenPart2
  #    goto LEnd
  #  lab2:
  #    elsePart
  #  Lend:
  if isEmpty(d) and not isEmptyType(n.typ): d = getTemp(c, n)
  var ending = newLabel(c.labelGen)
  for i in 0..<n.len:
    var it = n[i]
    if it.len == 2:
      let info = toLineInfo(c, it[0].info)
      withTemp(tmp, it[0]):
        var elsePos: LabelId
        if isNotOpr(it[0]):
          c.gen(it[0][1], tmp)
          elsePos = c.xjmp(it[0][1], opcTJmp, tmp) # if true
        else:
          c.gen(it[0], tmp)
          elsePos = c.xjmp(it[0], opcFJmp, tmp) # if false
      c.clearDest(n, d)
      if isEmptyType(it[1].typ): # maybe noreturn call, don't touch `d`
        c.genScope(it[1])
      else:
        c.genScope(it[1], d) # then part
      if i < n.len-1:
        c.jumpTo it[1], ending
      c.patch(it, elsePos)
    else:
      c.clearDest(n, d)
      if isEmptyType(it[0].typ): # maybe noreturn call, don't touch `d`
        c.genScope(it[0])
      else:
        c.genScope(it[0], d)
  c.patch(n, ending)
  c.clearDest(n, d)

proc tempToDest(c: var ProcCon; n: PNode; d: var Value; tmp: Value) =
  if isEmpty(d):
    d = tmp
  else:
    let info = toLineInfo(c, n.info)
    build c.code, info, Asgn:
      c.code.addTyped info, typeToIr(c.m.types, n.typ)
      c.code.copyTree d
      c.code.copyTree tmp
    freeTemp(c, tmp)

proc genAndOr(c: var ProcCon; n: PNode; opc: JmpKind; d: var Value) =
  #   asgn d, a
  #   tjmp|fjmp lab1
  #   asgn d, b
  # lab1:
  var tmp = getTemp(c, n)
  c.gen(n[1], tmp)
  let lab1 = c.xjmp(n, opc, tmp)
  c.gen(n[2], tmp)
  c.patch(n, lab1)
  tempToDest c, n, d, tmp

proc unused(c: var ProcCon; n: PNode; x: Value) {.inline.} =
  if hasValue(x):
    #debug(n)
    localError(c.config, n.info, "not unused")

proc caseValue(c: var ProcCon; n: PNode) =
  let info = toLineInfo(c, n.info)
  build c.code, info, SelectValue:
    let x = genx(c, n)
    c.code.copyTree x
    freeTemp(c, x)

proc caseRange(c: var ProcCon; n: PNode) =
  let info = toLineInfo(c, n.info)
  build c.code, info, SelectRange:
    let x = genx(c, n[0])
    let y = genx(c, n[1])
    c.code.copyTree x
    c.code.copyTree y
    freeTemp(c, y)
    freeTemp(c, x)

proc genCase(c: var ProcCon; n: PNode; d: var Value) =
  if not isEmptyType(n.typ):
    if isEmpty(d): d = getTemp(c, n)
  else:
    unused(c, n, d)
  var sections = newSeqOfCap[LabelId](n.len-1)
  let ending = newLabel(c.labelGen)
  let info = toLineInfo(c, n.info)
  withTemp(tmp, n[0]):
    build c.code, info, Select:
      c.code.addTyped info, typeToIr(c.m.types, n[0].typ)
      c.gen(n[0], tmp)
      for i in 1..<n.len:
        let section = newLabel(c.labelGen)
        sections.add section
        let it = n[i]
        let itinfo = toLineInfo(c, it.info)
        build c.code, itinfo, SelectPair:
          build c.code, itinfo, SelectList:
            for j in 0..<it.len-1:
              if it[j].kind == nkRange:
                caseRange c, it[j]
              else:
                caseValue c, it[j]
          c.code.addLabel itinfo, Goto, section
  for i in 1..<n.len:
    let it = n[i]
    let itinfo = toLineInfo(c, it.info)
    c.code.addLabel itinfo, Label, sections[i-1]
    c.gen it.lastSon
    if i != n.len-1:
      c.code.addLabel itinfo, Goto, ending
  c.code.addLabel info, Label, ending

proc rawCall(c: var ProcCon; info: PackedLineInfo; opc: Opcode; t: TypeId; args: var openArray[Value]) =
  build c.code, info, opc:
    c.code.addTyped info, t
    if opc in {CheckedCall, CheckedIndirectCall}:
      c.code.addLabel info, CheckedGoto, c.exitLabel
    for a in mitems(args):
      c.code.copyTree a
      freeTemp c, a

proc canRaiseDisp(p: ProcCon; n: PNode): bool =
  # we assume things like sysFatal cannot raise themselves
  if n.kind == nkSym and {sfNeverRaises, sfImportc, sfCompilerProc} * n.sym.flags != {}:
    result = false
  elif optPanics in p.config.globalOptions or
      (n.kind == nkSym and sfSystemModule in getModule(n.sym).flags and
       sfSystemRaisesDefect notin n.sym.flags):
    # we know we can be strict:
    result = canRaise(n)
  else:
    # we have to be *very* conservative:
    result = canRaiseConservative(n)

proc genCall(c: var ProcCon; n: PNode; d: var Value) =
  let canRaise = canRaiseDisp(c, n[0])

  let opc = if n[0].kind == nkSym and n[0].sym.kind in routineKinds:
              (if canRaise: CheckedCall else: Call)
            else:
              (if canRaise: CheckedIndirectCall else: IndirectCall)
  let info = toLineInfo(c, n.info)

  # In the IR we cannot nest calls. Thus we use two passes:
  var args: seq[Value] = @[]
  var t = n[0].typ
  if t != nil: t = t.skipTypes(abstractInst)
  args.add genx(c, n[0])
  for i in 1..<n.len:
    if t != nil and i < t.len:
      if isCompileTimeOnly(t[i]): discard
      elif isOutParam(t[i]): args.add genx(c, n[i], {gfToOutParam})
      else: args.add genx(c, n[i])
    else:
      args.add genx(c, n[i])

  let tb = typeToIr(c.m.types, n.typ)
  if not isEmptyType(n.typ):
    if isEmpty(d): d = getTemp(c, n)
    # XXX Handle problematic aliasing here: `a = f_canRaise(a)`.
    build c.code, info, Asgn:
      c.code.addTyped info, tb
      c.code.copyTree d
      rawCall c, info, opc, tb, args
  else:
    rawCall c, info, opc, tb, args

proc genRaise(c: var ProcCon; n: PNode) =
  let info = toLineInfo(c, n.info)
  let tb = typeToIr(c.m.types, n[0].typ)

  let d = genx(c, n[0])
  build c.code, info, SetExc:
    c.code.addTyped info, tb
    c.code.copyTree d
  c.freeTemp(d)
  c.code.addLabel info, Goto, c.exitLabel

proc genReturn(c: var ProcCon; n: PNode) =
  if n[0].kind != nkEmpty:
    gen(c, n[0])
  # XXX Block leave actions?
  let info = toLineInfo(c, n.info)
  c.code.addLabel info, Goto, c.exitLabel

proc genTry(c: var ProcCon; n: PNode; d: var Value) =
  if isEmpty(d) and not isEmptyType(n.typ): d = getTemp(c, n)
  var endings: seq[LabelId] = @[]
  let ehPos = newLabel(c.labelGen)
  let oldExitLab = c.exitLabel
  c.exitLabel = ehPos
  if isEmptyType(n[0].typ): # maybe noreturn call, don't touch `d`
    c.gen(n[0])
  else:
    c.gen(n[0], d)
  c.clearDest(n, d)

  # Add a jump past the exception handling code
  let jumpToFinally = newLabel(c.labelGen)
  c.jumpTo n, jumpToFinally
  # This signals where the body ends and where the exception handling begins
  c.patch(n, ehPos)
  c.exitLabel = oldExitLab
  for i in 1..<n.len:
    let it = n[i]
    if it.kind != nkFinally:
      # first opcExcept contains the end label of the 'except' block:
      let endExcept = newLabel(c.labelGen)
      for j in 0..<it.len - 1:
        assert(it[j].kind == nkType)
        let typ = it[j].typ.skipTypes(abstractPtrs-{tyTypeDesc})
        let itinfo = toLineInfo(c, it[j].info)
        build c.code, itinfo, TestExc:
          c.code.addTyped itinfo, typeToIr(c.m.types, typ)
      if it.len == 1:
        let itinfo = toLineInfo(c, it.info)
        build c.code, itinfo, TestExc:
          c.code.addTyped itinfo, VoidId
      let body = it.lastSon
      if isEmptyType(body.typ): # maybe noreturn call, don't touch `d`
        c.gen(body)
      else:
        c.gen(body, d)
      c.clearDest(n, d)
      if i < n.len:
        endings.add newLabel(c.labelGen)
      c.patch(it, endExcept)
  let fin = lastSon(n)
  # we always generate an 'opcFinally' as that pops the safepoint
  # from the stack if no exception is raised in the body.
  c.patch(fin, jumpToFinally)
  #c.gABx(fin, opcFinally, 0, 0)
  for endPos in endings: c.patch(n, endPos)
  if fin.kind == nkFinally:
    c.gen(fin[0])
    c.clearDest(n, d)
  #c.gABx(fin, opcFinallyEnd, 0, 0)

template isGlobal(s: PSym): bool = sfGlobal in s.flags and s.kind != skForVar
proc isGlobal(n: PNode): bool = n.kind == nkSym and isGlobal(n.sym)

proc genField(c: var ProcCon; n: PNode; d: var Value) =
  var pos: int
  if n.kind != nkSym or n.sym.kind != skField:
    localError(c.config, n.info, "no field symbol")
    pos = 0
  else:
    pos = n.sym.position
  d.addImmediateVal toLineInfo(c, n.info), pos

proc genIndex(c: var ProcCon; n: PNode; arr: PType; d: var Value) =
  if arr.skipTypes(abstractInst).kind == tyArray and
      (let x = firstOrd(c.config, arr); x != Zero):
    let info = toLineInfo(c, n.info)
    buildTyped d, info, Sub, c.m.nativeIntId:
      c.gen(n, d)
      d.addImmediateVal toLineInfo(c, n.info), toInt(x)
  else:
    c.gen(n, d)

proc genNew(c: var ProcCon; n: PNode; needsInit: bool) =
  # If in doubt, always follow the blueprint of the C code generator for `mm:orc`.
  let refType = n[1].typ.skipTypes(abstractInstOwned)
  assert refType.kind == tyRef
  let baseType = refType.lastSon

  let info = toLineInfo(c, n.info)
  let codegenProc = magicsys.getCompilerProc(c.m.graph,
    if needsInit: "nimNewObj" else: "nimNewObjUninit")
  let x = genx(c, n[1])
  let refTypeIr = typeToIr(c.m.types, refType)
  buildTyped c.code, info, Asgn, refTypeIr:
    copyTree c.code, x
    buildTyped c.code, info, Cast, refTypeIr:
      buildTyped c.code, info, Call, VoidPtrId:
        let theProc = c.genx newSymNode(codegenProc, n.info)
        copyTree c.code, theProc
        c.code.addImmediateVal info, int(getSize(c.config, baseType))
        c.code.addImmediateVal info, int(getAlign(c.config, baseType))

proc genNewSeqOfCap(c: var ProcCon; n: PNode; d: var Value) =
  let info = toLineInfo(c, n.info)
  let seqtype = skipTypes(n.typ, abstractVarRange)
  let baseType = seqtype.lastSon
  var a = c.genx(n[1])
  if isEmpty(d): d = getTemp(c, n)
  # $1.len = 0
  buildTyped c.code, info, Asgn, c.m.nativeIntId:
    buildTyped c.code, info, FieldAt, c.m.nativeIntId:
      copyTree c.code, d
      c.code.addImmediateVal info, 0
    c.code.addImmediateVal info, 0
  # $1.p = ($4*) #newSeqPayloadUninit($2, sizeof($3), NIM_ALIGNOF($3))
  let payloadPtr = seqPayloadPtrType(c.m.types, seqtype)
  buildTyped c.code, info, Asgn, payloadPtr:
    # $1.p
    buildTyped c.code, info, FieldAt, payloadPtr:
      copyTree c.code, d
      c.code.addImmediateVal info, 1
    # ($4*) #newSeqPayloadUninit($2, sizeof($3), NIM_ALIGNOF($3))
    buildTyped c.code, info, Cast, payloadPtr:
      buildTyped c.code, info, Call, VoidPtrId:
        let codegenProc = magicsys.getCompilerProc(c.m.graph, "newSeqPayloadUninit")
        let theProc = c.genx newSymNode(codegenProc, n.info)
        copyTree c.code, theProc
        copyTree c.code, a
        c.code.addImmediateVal info, int(getSize(c.config, baseType))
        c.code.addImmediateVal info, int(getAlign(c.config, baseType))
  freeTemp c, a

proc genNewSeq(c: var ProcCon; n: PNode) =
  let info = toLineInfo(c, n.info)
  let seqtype = skipTypes(n[1].typ, abstractVarRange)
  let baseType = seqtype.lastSon
  var d = c.genx(n[1])
  var b = c.genx(n[2])

  # $1.len = $2
  buildTyped c.code, info, Asgn, c.m.nativeIntId:
    buildTyped c.code, info, FieldAt, c.m.nativeIntId:
      copyTree c.code, d
      c.code.addImmediateVal info, 0
    copyTree c.code, b
    c.code.addImmediateVal info, 0

  # $1.p = ($4*) #newSeqPayload($2, sizeof($3), NIM_ALIGNOF($3))
  let payloadPtr = seqPayloadPtrType(c.m.types, seqtype)
  buildTyped c.code, info, Asgn, payloadPtr:
    # $1.p
    buildTyped c.code, info, FieldAt, payloadPtr:
      copyTree c.code, d
      c.code.addImmediateVal info, 1
    # ($4*) #newSeqPayload($2, sizeof($3), NIM_ALIGNOF($3))
    buildTyped c.code, info, Cast, payloadPtr:
      buildTyped c.code, info, Call, VoidPtrId:
        let codegenProc = magicsys.getCompilerProc(c.m.graph, "newSeqPayload")
        let theProc = c.genx newSymNode(codegenProc, n.info)
        copyTree c.code, theProc
        copyTree c.code, b
        c.code.addImmediateVal info, int(getSize(c.config, baseType))
        c.code.addImmediateVal info, int(getAlign(c.config, baseType))
  freeTemp c, b
  freeTemp c, d

template intoDest*(d: var Value; info: PackedLineInfo; typ: TypeId; body: untyped) =
  if typ == VoidId:
    body(c.code)
  elif isEmpty(d):
    body(Tree(d))
  else:
    buildTyped c.code, info, Asgn, typ:
      copyTree c.code, d
      body(c.code)

proc genBinaryOp(c: var ProcCon; n: PNode; d: var Value; opc: Opcode) =
  let info = toLineInfo(c, n.info)
  let tmp = c.genx(n[1])
  let tmp2 = c.genx(n[2])
  let t = typeToIr(c.m.types, n.typ)
  template body(target) =
    buildTyped target, info, opc, t:
      copyTree target, tmp
      copyTree target, tmp2
  intoDest d, info, t, body
  c.freeTemp(tmp)
  c.freeTemp(tmp2)

proc genUnaryOp(c: var ProcCon; n: PNode; d: var Value; opc: Opcode) =
  let info = toLineInfo(c, n.info)
  let tmp = c.genx(n[1])
  let t = typeToIr(c.m.types, n.typ)
  template body(target) =
    buildTyped target, info, opc, t:
      copyTree target, tmp
  intoDest d, info, t, body
  c.freeTemp(tmp)

proc genIncDec(c: var ProcCon; n: PNode; opc: Opcode) =
  let info = toLineInfo(c, n.info)
  let t = typeToIr(c.m.types, skipTypes(n[1].typ, abstractVar))

  let d = c.genx(n[1])
  let tmp = c.genx(n[2])
  # we produce code like:  i = i + 1
  buildTyped c.code, info, Asgn, t:
    copyTree c.code, d
    buildTyped c.code, info, opc, t:
      copyTree c.code, d
      copyTree c.code, tmp
  c.freeTemp(tmp)
  #c.genNarrow(n[1], d)
  c.freeTemp(d)

proc genArrayLen(c: var ProcCon; n: PNode; d: var Value) =
  let info = toLineInfo(c, n.info)
  var a = n[1]
  #if a.kind == nkHiddenAddr: a = a[0]
  var typ = skipTypes(a.typ, abstractVar + tyUserTypeClasses)
  case typ.kind
  of tyOpenArray, tyVarargs:
    let xa = c.genx(a)
    template body(target) =
      buildTyped target, info, FieldAt, c.m.nativeIntId:
        copyTree target, xa
        target.addImmediateVal info, 1 # (p, len)-pair so len is at index 1
    intoDest d, info, c.m.nativeIntId, body

  of tyCstring:
    let xa = c.genx(a)
    if isEmpty(d): d = getTemp(c, n)
    buildTyped c.code, info, Call, c.m.nativeIntId:
      let codegenProc = magicsys.getCompilerProc(c.m.graph, "nimCStrLen")
      let theProc = c.genx newSymNode(codegenProc, n.info)
      copyTree c.code, theProc
      copyTree c.code, xa

  of tyString, tySequence:
    let xa = c.genx(a)

    if typ.kind == tySequence:
      # we go through a temporary here because people write bullshit code.
      if isEmpty(d): d = getTemp(c, n)

    template body(target) =
      buildTyped target, info, FieldAt, c.m.nativeIntId:
        copyTree target, xa
        target.addImmediateVal info, 0 # (len, p)-pair so len is at index 0
    intoDest d, info, c.m.nativeIntId, body

  of tyArray:
    template body(target) =
      target.addIntVal(c.m.integers, info, c.m.nativeIntId, toInt lengthOrd(c.config, typ))
    intoDest d, info, c.m.nativeIntId, body
  else: internalError(c.config, n.info, "genArrayLen()")

proc genUnaryMinus(c: var ProcCon; n: PNode; d: var Value) =
  let info = toLineInfo(c, n.info)
  let tmp = c.genx(n[1])
  let t = typeToIr(c.m.types, n.typ)
  template body(target) =
    buildTyped target, info, Sub, t:
      # Little hack: This works because we know that `0.0` is all 0 bits:
      target.addIntVal(c.m.integers, info, t, 0)
      copyTree target, tmp
  intoDest d, info, t, body
  c.freeTemp(tmp)

proc genHigh(c: var ProcCon; n: PNode; d: var Value) =
  let subOpr = createMagic(c.m.graph, c.m.idgen, "-", mSubI)
  let lenOpr = createMagic(c.m.graph, c.m.idgen, "len", mLengthOpenArray)
  let asLenExpr = subOpr.buildCall(lenOpr.buildCall(n[1]), nkIntLit.newIntNode(1))
  c.gen asLenExpr, d

proc genBinaryCp(c: var ProcCon; n: PNode; d: var Value; compilerProc: string) =
  let info = toLineInfo(c, n.info)
  let xa = c.genx(n[1])
  let xb = c.genx(n[2])
  if isEmpty(d) and not isEmptyType(n.typ): d = getTemp(c, n)

  let t = typeToIr(c.m.types, n.typ)
  template body(target) =
    buildTyped target, info, Call, t:
      let codegenProc = magicsys.getCompilerProc(c.m.graph, compilerProc)
      let theProc = c.genx newSymNode(codegenProc, n.info)
      copyTree target, theProc
      copyTree target, xa
      copyTree target, xb

  intoDest d, info, t, body
  c.freeTemp xb
  c.freeTemp xa

proc genUnaryCp(c: var ProcCon; n: PNode; d: var Value; compilerProc: string; argAt = 1) =
  let info = toLineInfo(c, n.info)
  let xa = c.genx(n[argAt])
  if isEmpty(d) and not isEmptyType(n.typ): d = getTemp(c, n)

  let t = typeToIr(c.m.types, n.typ)
  template body(target) =
    buildTyped target, info, Call, t:
      let codegenProc = magicsys.getCompilerProc(c.m.graph, compilerProc)
      let theProc = c.genx newSymNode(codegenProc, n.info)
      copyTree target, theProc
      copyTree target, xa

  intoDest d, info, t, body
  c.freeTemp xa

proc genEnumToStr(c: var ProcCon; n: PNode; d: var Value) =
  let t = n[1].typ.skipTypes(abstractInst+{tyRange})
  let toStrProc = getToStringProc(c.m.graph, t)
  # XXX need to modify this logic for IC.
  var nb = copyTree(n)
  nb[0] = newSymNode(toStrProc)
  gen(c, nb, d)

template sizeOfLikeMsg(name): string =
  "'" & name & "' requires '.importc' types to be '.completeStruct'"

proc genMagic(c: var ProcCon; n: PNode; d: var Value; m: TMagic) =
  case m
  of mAnd: c.genAndOr(n, opcFJmp, d)
  of mOr: c.genAndOr(n, opcTJmp, d)
  of mPred, mSubI: c.genBinaryOp(n, d, CheckedSub)
  of mSucc, mAddI: c.genBinaryOp(n, d, CheckedAdd)
  of mInc:
    unused(c, n, d)
    c.genIncDec(n, CheckedAdd)
  of mDec:
    unused(c, n, d)
    c.genIncDec(n, CheckedSub)
  of mOrd, mChr, mArrToSeq, mUnown:
    c.gen(n[1], d)
  of generatedMagics:
    genCall(c, n, d)
  of mNew, mNewFinalize:
    unused(c, n, d)
    c.genNew(n, needsInit = true)
  of mNewSeq:
    unused(c, n, d)
    c.genNewSeq(n)
  of mNewSeqOfCap: c.genNewSeqOfCap(n, d)
  of mNewString, mNewStringOfCap, mExit: c.genCall(n, d)
  of mLengthOpenArray, mLengthArray, mLengthSeq, mLengthStr:
    genArrayLen(c, n, d)
  of mMulI: genBinaryOp(c, n, d, Mul)
  of mDivI: genBinaryOp(c, n, d, Div)
  of mModI: genBinaryOp(c, n, d, Mod)
  of mAddF64: genBinaryOp(c, n, d, Add)
  of mSubF64: genBinaryOp(c, n, d, Sub)
  of mMulF64: genBinaryOp(c, n, d, Mul)
  of mDivF64: genBinaryOp(c, n, d, Div)
  of mShrI: genBinaryOp(c, n, d, BitShr)
  of mShlI: genBinaryOp(c, n, d, BitShl)
  of mAshrI: genBinaryOp(c, n, d, BitShr)
  of mBitandI: genBinaryOp(c, n, d, BitAnd)
  of mBitorI: genBinaryOp(c, n, d, BitOr)
  of mBitxorI: genBinaryOp(c, n, d, BitXor)
  of mAddU: genBinaryOp(c, n, d, Add)
  of mSubU: genBinaryOp(c, n, d, Sub)
  of mMulU: genBinaryOp(c, n, d, Mul)
  of mDivU: genBinaryOp(c, n, d, Div)
  of mModU: genBinaryOp(c, n, d, Mod)
  of mEqI, mEqB, mEqEnum, mEqCh:
    genBinaryOp(c, n, d, Eq)
  of mLeI, mLeEnum, mLeCh, mLeB:
    genBinaryOp(c, n, d, Le)
  of mLtI, mLtEnum, mLtCh, mLtB:
    genBinaryOp(c, n, d, Lt)
  of mEqF64: genBinaryOp(c, n, d, Eq)
  of mLeF64: genBinaryOp(c, n, d, Le)
  of mLtF64: genBinaryOp(c, n, d, Lt)
  of mLePtr, mLeU: genBinaryOp(c, n, d, Le)
  of mLtPtr, mLtU: genBinaryOp(c, n, d, Lt)
  of mEqProc, mEqRef:
    genBinaryOp(c, n, d, Eq)
  of mXor: genBinaryOp(c, n, d, BitXor)
  of mNot: genUnaryOp(c, n, d, BoolNot)
  of mUnaryMinusI, mUnaryMinusI64:
    genUnaryMinus(c, n, d)
    #genNarrow(c, n, d)
  of mUnaryMinusF64: genUnaryMinus(c, n, d)
  of mUnaryPlusI, mUnaryPlusF64: gen(c, n[1], d)
  of mBitnotI:
    genUnaryOp(c, n, d, BitNot)
    when false:
      # XXX genNarrowU modified, do not narrow signed types
      let t = skipTypes(n.typ, abstractVar-{tyTypeDesc})
      let size = getSize(c.config, t)
      if t.kind in {tyUInt8..tyUInt32} or (t.kind == tyUInt and size < 8):
        c.gABC(n, opcNarrowU, d, TRegister(size*8))
  of mStrToStr, mEnsureMove: c.gen n[1], d
  of mIntToStr: genUnaryCp(c, n, d, "nimIntToStr")
  of mInt64ToStr: genUnaryCp(c, n, d, "nimInt64ToStr")
  of mBoolToStr: genUnaryCp(c, n, d, "nimBoolToStr")
  of mCharToStr: genUnaryCp(c, n, d, "nimCharToStr")
  of mFloatToStr:
    if n[1].typ.skipTypes(abstractInst).kind == tyFloat32:
      genUnaryCp(c, n, d, "nimFloat32ToStr")
    else:
      genUnaryCp(c, n, d, "nimFloatToStr")
  of mCStrToStr: genUnaryCp(c, n, d, "cstrToNimstr")
  of mEnumToStr: genEnumToStr(c, n, d)

  of mEqStr: genBinaryCp(c, n, d, "eqStrings")
  of mEqCString: genCall(c, n, d)
  of mLeStr: genBinaryCp(c, n, d, "leStrings")
  of mLtStr: genBinaryCp(c, n, d, "ltStrings")

  of mSetLengthStr:
    unused(c, n, d)
    let nb = copyTree(n)
    nb[1] = makeAddr(nb[1], c.m.idgen)
    genBinaryCp(c, nb, d, "setLengthStrV2")

  of mSetLengthSeq:
    unused(c, n, d)
    let nb = copyTree(n)
    nb[1] = makeAddr(nb[1], c.m.idgen)
    genCall(c, nb, d)

  of mSwap:
    unused(c, n, d)
    c.gen(lowerSwap(c.m.graph, n, c.m.idgen,
      if c.prc == nil: c.m.module else: c.prc), d)
  of mParseBiggestFloat:
    genCall c, n, d
  of mHigh:
    c.genHigh n, d

  of mEcho:
    unused(c, n, d)
    genUnaryCp c, n, d, "echoBinSafe"

  of mAppendStrCh:
    unused(c, n, d)
    let nb = copyTree(n)
    nb[1] = makeAddr(nb[1], c.m.idgen)
    genBinaryCp(c, nb, d, "nimAddCharV1")
  of mMinI, mMaxI, mAbsI, mDotDot:
    c.genCall(n, d)
  of mSizeOf:
    localError(c.config, n.info, sizeOfLikeMsg("sizeof"))
  of mAlignOf:
    localError(c.config, n.info, sizeOfLikeMsg("alignof"))
  of mOffsetOf:
    localError(c.config, n.info, sizeOfLikeMsg("offsetof"))
  of mRunnableExamples:
    discard "just ignore any call to runnableExamples"
  of mDestroy, mTrace: discard "ignore calls to the default destructor"
  else:
    # mGCref, mGCunref,
    globalError(c.config, n.info, "cannot generate code for: " & $m)

#[

  of mIsNil: genUnaryABC(c, n, d, opcIsNil)
  of mReset:
    unused(c, n, d)
    var d = c.genx(n[1])
    # XXX use ldNullOpcode() here?
    c.gABx(n, opcLdNull, d, c.genType(n[1].typ))
    c.gABC(n, opcNodeToReg, d, d)
  of mDefault, mZeroDefault:
    if isEmpty(d): d = c.getTemp(n)
    c.gABx(n, ldNullOpcode(n.typ), d, c.genType(n.typ))
  of mOf:
    if isEmpty(d): d = c.getTemp(n)
    var tmp = c.genx(n[1])
    var idx = c.getTemp(getSysType(c.graph, n.info, tyInt))
    var typ = n[2].typ
    if m == mOf: typ = typ.skipTypes(abstractPtrs)
    c.gABx(n, opcLdImmInt, idx, c.genType(typ))
    c.gABC(n, opcOf, d, tmp, idx)
    c.freeTemp(tmp)
    c.freeTemp(idx)

  of mAppendStrStr:
    unused(c, n, d)
    genBinaryStmtVar(c, n, opcAddStrStr)
  of mAppendSeqElem:
    unused(c, n, d)
    genBinaryStmtVar(c, n, opcAddSeqElem)

  of mCard: genCard(c, n, d)
  of mEqSet: genBinarySet(c, n, d, opcEqSet)
  of mLeSet: genBinarySet(c, n, d, opcLeSet)
  of mLtSet: genBinarySet(c, n, d, opcLtSet)
  of mMulSet: genBinarySet(c, n, d, opcMulSet)
  of mPlusSet: genBinarySet(c, n, d, opcPlusSet)
  of mMinusSet: genBinarySet(c, n, d, opcMinusSet)
  of mConStrStr: genVarargsABC(c, n, d, opcConcatStr)
  of mInSet: genBinarySet(c, n, d, opcContainsSet)

  of mRepr: genUnaryABC(c, n, d, opcRepr)

  of mSlice:
    var
      d = c.genx(n[1])
      left = c.genIndex(n[2], n[1].typ)
      right = c.genIndex(n[3], n[1].typ)
    if isEmpty(d): d = c.getTemp(n)
    c.gABC(n, opcNodeToReg, d, d)
    c.gABC(n, opcSlice, d, left, right)
    c.freeTemp(left)
    c.freeTemp(right)
    c.freeTemp(d)

  of mIncl, mExcl:
    unused(c, n, d)
    var d = c.genx(n[1])
    var tmp = c.genx(n[2])
    c.genSetType(n[1], d)
    c.gABC(n, if m == mIncl: opcIncl else: opcExcl, d, tmp)
    c.freeTemp(d)
    c.freeTemp(tmp)
  of mMove:
    let arg = n[1]
    let a = c.genx(arg)
    if isEmpty(d): d = c.getTemp(arg)
    gABC(c, arg, whichAsgnOpc(arg, requiresCopy=false), d, a)
    c.freeTemp(a)
  of mDup:
    let arg = n[1]
    let a = c.genx(arg)
    if isEmpty(d): d = c.getTemp(arg)
    gABC(c, arg, whichAsgnOpc(arg, requiresCopy=false), d, a)
    c.freeTemp(a)
  of mNodeId:
    c.genUnaryABC(n, d, opcNodeId)

  of mExpandToAst:
    if n.len != 2:
      globalError(c.config, n.info, "expandToAst requires 1 argument")
    let arg = n[1]
    if arg.kind in nkCallKinds:
      #if arg[0].kind != nkSym or arg[0].sym.kind notin {skTemplate, skMacro}:
      #      "ExpandToAst: expanded symbol is no macro or template"
      if isEmpty(d): d = c.getTemp(n)
      c.genCall(arg, d)
      # do not call clearDest(n, d) here as getAst has a meta-type as such
      # produces a value
    else:
      globalError(c.config, n.info, "expandToAst requires a call expression")
  of mParseExprToAst:
    genBinaryABC(c, n, d, opcParseExprToAst)
  of mParseStmtToAst:
    genBinaryABC(c, n, d, opcParseStmtToAst)
  of mTypeTrait:
    let tmp = c.genx(n[1])
    if isEmpty(d): d = c.getTemp(n)
    c.gABx(n, opcSetType, tmp, c.genType(n[1].typ))
    c.gABC(n, opcTypeTrait, d, tmp)
    c.freeTemp(tmp)
  of mSlurp: genUnaryABC(c, n, d, opcSlurp)
  of mNLen: genUnaryABI(c, n, d, opcLenSeq, nimNodeFlag)
  of mGetImpl: genUnaryABC(c, n, d, opcGetImpl)
  of mGetImplTransf: genUnaryABC(c, n, d, opcGetImplTransf)
  of mSymOwner: genUnaryABC(c, n, d, opcSymOwner)
  of mSymIsInstantiationOf: genBinaryABC(c, n, d, opcSymIsInstantiationOf)
  of mNChild: genBinaryABC(c, n, d, opcNChild)
  of mNAdd: genBinaryABC(c, n, d, opcNAdd)
  of mNAddMultiple: genBinaryABC(c, n, d, opcNAddMultiple)
  of mNKind: genUnaryABC(c, n, d, opcNKind)
  of mNSymKind: genUnaryABC(c, n, d, opcNSymKind)

  of mNccValue: genUnaryABC(c, n, d, opcNccValue)
  of mNccInc: genBinaryABC(c, n, d, opcNccInc)
  of mNcsAdd: genBinaryABC(c, n, d, opcNcsAdd)
  of mNcsIncl: genBinaryABC(c, n, d, opcNcsIncl)
  of mNcsLen: genUnaryABC(c, n, d, opcNcsLen)
  of mNcsAt: genBinaryABC(c, n, d, opcNcsAt)
  of mNctLen: genUnaryABC(c, n, d, opcNctLen)
  of mNctGet: genBinaryABC(c, n, d, opcNctGet)
  of mNctHasNext: genBinaryABC(c, n, d, opcNctHasNext)
  of mNctNext: genBinaryABC(c, n, d, opcNctNext)

  of mNIntVal: genUnaryABC(c, n, d, opcNIntVal)
  of mNFloatVal: genUnaryABC(c, n, d, opcNFloatVal)
  of mNSymbol: genUnaryABC(c, n, d, opcNSymbol)
  of mNIdent: genUnaryABC(c, n, d, opcNIdent)
  of mNGetType:
    let tmp = c.genx(n[1])
    if isEmpty(d): d = c.getTemp(n)
    let rc = case n[0].sym.name.s:
      of "getType": 0
      of "typeKind": 1
      of "getTypeInst": 2
      else: 3  # "getTypeImpl"
    c.gABC(n, opcNGetType, d, tmp, rc)
    c.freeTemp(tmp)
    #genUnaryABC(c, n, d, opcNGetType)
  of mNSizeOf:
    let imm = case n[0].sym.name.s:
      of "getSize": 0
      of "getAlign": 1
      else: 2 # "getOffset"
    c.genUnaryABI(n, d, opcNGetSize, imm)
  of mNStrVal: genUnaryABC(c, n, d, opcNStrVal)
  of mNSigHash: genUnaryABC(c, n , d, opcNSigHash)
  of mNSetIntVal:
    unused(c, n, d)
    genBinaryStmt(c, n, opcNSetIntVal)
  of mNSetFloatVal:
    unused(c, n, d)
    genBinaryStmt(c, n, opcNSetFloatVal)
  of mNSetSymbol:
    unused(c, n, d)
    genBinaryStmt(c, n, opcNSetSymbol)
  of mNSetIdent:
    unused(c, n, d)
    genBinaryStmt(c, n, opcNSetIdent)
  of mNSetStrVal:
    unused(c, n, d)
    genBinaryStmt(c, n, opcNSetStrVal)
  of mNNewNimNode: genBinaryABC(c, n, d, opcNNewNimNode)
  of mNCopyNimNode: genUnaryABC(c, n, d, opcNCopyNimNode)
  of mNCopyNimTree: genUnaryABC(c, n, d, opcNCopyNimTree)
  of mNBindSym: genBindSym(c, n, d)
  of mStrToIdent: genUnaryABC(c, n, d, opcStrToIdent)
  of mEqIdent: genBinaryABC(c, n, d, opcEqIdent)
  of mEqNimrodNode: genBinaryABC(c, n, d, opcEqNimNode)
  of mSameNodeType: genBinaryABC(c, n, d, opcSameNodeType)
  of mNLineInfo:
    case n[0].sym.name.s
    of "getFile": genUnaryABI(c, n, d, opcNGetLineInfo, 0)
    of "getLine": genUnaryABI(c, n, d, opcNGetLineInfo, 1)
    of "getColumn": genUnaryABI(c, n, d, opcNGetLineInfo, 2)
    of "copyLineInfo":
      internalAssert c.config, n.len == 3
      unused(c, n, d)
      genBinaryStmt(c, n, opcNCopyLineInfo)
    of "setLine":
      internalAssert c.config, n.len == 3
      unused(c, n, d)
      genBinaryStmt(c, n, opcNSetLineInfoLine)
    of "setColumn":
      internalAssert c.config, n.len == 3
      unused(c, n, d)
      genBinaryStmt(c, n, opcNSetLineInfoColumn)
    of "setFile":
      internalAssert c.config, n.len == 3
      unused(c, n, d)
      genBinaryStmt(c, n, opcNSetLineInfoFile)
    else: internalAssert c.config, false
  of mNHint:
    unused(c, n, d)
    genBinaryStmt(c, n, opcNHint)
  of mNWarning:
    unused(c, n, d)
    genBinaryStmt(c, n, opcNWarning)
  of mNError:
    if n.len <= 1:
      # query error condition:
      c.gABC(n, opcQueryErrorFlag, d)
    else:
      # setter
      unused(c, n, d)
      genBinaryStmt(c, n, opcNError)
  of mNCallSite:
    if isEmpty(d): d = c.getTemp(n)
    c.gABC(n, opcCallSite, d)
  of mNGenSym: genBinaryABC(c, n, d, opcGenSym)

]#

proc canElimAddr(n: PNode; idgen: IdGenerator): PNode =
  result = nil
  case n[0].kind
  of nkObjUpConv, nkObjDownConv, nkChckRange, nkChckRangeF, nkChckRange64:
    var m = n[0][0]
    if m.kind in {nkDerefExpr, nkHiddenDeref}:
      # addr ( nkConv ( deref ( x ) ) ) --> nkConv(x)
      result = copyNode(n[0])
      result.add m[0]
      if n.typ.skipTypes(abstractVar).kind != tyOpenArray:
        result.typ = n.typ
      elif n.typ.skipTypes(abstractInst).kind in {tyVar}:
        result.typ = toVar(result.typ, n.typ.skipTypes(abstractInst).kind, idgen)
  of nkHiddenStdConv, nkHiddenSubConv, nkConv:
    var m = n[0][1]
    if m.kind in {nkDerefExpr, nkHiddenDeref}:
      # addr ( nkConv ( deref ( x ) ) ) --> nkConv(x)
      result = copyNode(n[0])
      result.add n[0][0]
      result.add m[0]
      if n.typ.skipTypes(abstractVar).kind != tyOpenArray:
        result.typ = n.typ
      elif n.typ.skipTypes(abstractInst).kind in {tyVar}:
        result.typ = toVar(result.typ, n.typ.skipTypes(abstractInst).kind, idgen)
  else:
    if n[0].kind in {nkDerefExpr, nkHiddenDeref}:
      # addr ( deref ( x )) --> x
      result = n[0][0]

template valueIntoDest(c: var ProcCon; info: PackedLineInfo; d: var Value; typ: PType; body: untyped) =
  if isEmpty(d):
    body(Tree d)
  else:
    buildTyped c.code, info, Asgn, typeToIr(c.m.types, typ):
      copyTree c.code, d
      body(c.code)

proc genAddr(c: var ProcCon; n: PNode, d: var Value, flags: GenFlags) =
  if (let m = canElimAddr(n, c.m.idgen); m != nil):
    gen(c, m, d, flags)
    return

  let info = toLineInfo(c, n.info)
  let tmp = c.genx(n[0], flags)
  template body(target) =
    buildTyped target, info, AddrOf, typeToIr(c.m.types, n.typ):
      copyTree target, tmp

  valueIntoDest c, info, d, n.typ, body
  freeTemp c, tmp

proc genDeref(c: var ProcCon; n: PNode, d: var Value, flags: GenFlags) =
  let info = toLineInfo(c, n.info)
  let tmp = c.genx(n[0], flags)
  template body(target) =
    buildTyped target, info, Load, typeToIr(c.m.types, n.typ):
      copyTree target, tmp

  valueIntoDest c, info, d, n.typ, body
  freeTemp c, tmp

#[
proc genCheckedObjAccessAux(c: var ProcCon; n: PNode; d: var Value; flags: GenFlags)

proc genConv(c: var ProcCon; n, arg: PNode; d: var Value; opc=opcConv) =
  let t2 = n.typ.skipTypes({tyDistinct})
  let targ2 = arg.typ.skipTypes({tyDistinct})

  proc implicitConv(): bool =
    if sameBackendType(t2, targ2): return true
    # xxx consider whether to use t2 and targ2 here
    if n.typ.kind == arg.typ.kind and arg.typ.kind == tyProc:
      # don't do anything for lambda lifting conversions:
      result = true
    else:
      result = false

  if implicitConv():
    gen(c, arg, d)
    return

  let tmp = c.genx(arg)
  if isEmpty(d): d = c.getTemp(n)
  c.gABC(n, opc, d, tmp)
  c.gABx(n, opc, 0, genType(c, n.typ.skipTypes({tyStatic})))
  c.gABx(n, opc, 0, genType(c, arg.typ.skipTypes({tyStatic})))
  c.freeTemp(tmp)

proc genCard(c: var ProcCon; n: PNode; d: var Value) =
  let tmp = c.genx(n[1])
  if isEmpty(d): d = c.getTemp(n)
  c.genSetType(n[1], tmp)
  c.gABC(n, opcCard, d, tmp)
  c.freeTemp(tmp)

proc genCastIntFloat(c: var ProcCon; n: PNode; d: var Value) =
  const allowedIntegers = {tyInt..tyInt64, tyUInt..tyUInt64, tyChar}
  var signedIntegers = {tyInt..tyInt64}
  var unsignedIntegers = {tyUInt..tyUInt64, tyChar}
  let src = n[1].typ.skipTypes(abstractRange)#.kind
  let dst = n[0].typ.skipTypes(abstractRange)#.kind
  let srcSize = getSize(c.config, src)
  let dstSize = getSize(c.config, dst)
  const unsupportedCastDifferentSize =
    "VM does not support 'cast' from $1 with size $2 to $3 with size $4 due to different sizes"
  if src.kind in allowedIntegers and dst.kind in allowedIntegers:
    let tmp = c.genx(n[1])
    if isEmpty(d): d = c.getTemp(n[0])
    c.gABC(n, opcAsgnInt, d, tmp)
    if dstSize != sizeof(BiggestInt): # don't do anything on biggest int types
      if dst.kind in signedIntegers: # we need to do sign extensions
        if dstSize <= srcSize:
          # Sign extension can be omitted when the size increases.
          c.gABC(n, opcSignExtend, d, TRegister(dstSize*8))
      elif dst.kind in unsignedIntegers:
        if src.kind in signedIntegers or dstSize < srcSize:
          # Cast from signed to unsigned always needs narrowing. Cast
          # from unsigned to unsigned only needs narrowing when target
          # is smaller than source.
          c.gABC(n, opcNarrowU, d, TRegister(dstSize*8))
    c.freeTemp(tmp)
  elif src.kind in allowedIntegers and
      dst.kind in {tyFloat, tyFloat32, tyFloat64}:
    if srcSize != dstSize:
      globalError(c.config, n.info, unsupportedCastDifferentSize %
        [$src.kind, $srcSize, $dst.kind, $dstSize])
    let tmp = c.genx(n[1])
    if isEmpty(d): d = c.getTemp(n[0])
    if dst.kind == tyFloat32:
      c.gABC(n, opcCastIntToFloat32, d, tmp)
    else:
      c.gABC(n, opcCastIntToFloat64, d, tmp)
    c.freeTemp(tmp)

  elif src.kind in {tyFloat, tyFloat32, tyFloat64} and
                           dst.kind in allowedIntegers:
    if srcSize != dstSize:
      globalError(c.config, n.info, unsupportedCastDifferentSize %
        [$src.kind, $srcSize, $dst.kind, $dstSize])
    let tmp = c.genx(n[1])
    if isEmpty(d): d = c.getTemp(n[0])
    if src.kind == tyFloat32:
      c.gABC(n, opcCastFloatToInt32, d, tmp)
      if dst.kind in unsignedIntegers:
        # integers are sign extended by default.
        # since there is no opcCastFloatToUInt32, narrowing should do the trick.
        c.gABC(n, opcNarrowU, d, TRegister(32))
    else:
      c.gABC(n, opcCastFloatToInt64, d, tmp)
      # narrowing for 64 bits not needed (no extended sign bits available).
    c.freeTemp(tmp)
  elif src.kind in PtrLikeKinds + {tyRef} and dst.kind == tyInt:
    let tmp = c.genx(n[1])
    if isEmpty(d): d = c.getTemp(n[0])
    var imm: BiggestInt = if src.kind in PtrLikeKinds: 1 else: 2
    c.gABI(n, opcCastPtrToInt, d, tmp, imm)
    c.freeTemp(tmp)
  elif src.kind in PtrLikeKinds + {tyInt} and dst.kind in PtrLikeKinds:
    let tmp = c.genx(n[1])
    if isEmpty(d): d = c.getTemp(n[0])
    c.gABx(n, opcSetType, d, c.genType(dst))
    c.gABC(n, opcCastIntToPtr, d, tmp)
    c.freeTemp(tmp)
  elif src.kind == tyNil and dst.kind in NilableTypes:
    # supports casting nil literals to NilableTypes in VM
    # see #16024
    if isEmpty(d): d = c.getTemp(n[0])
    genLit(c, n[1], d)
  else:
    # todo: support cast from tyInt to tyRef
    globalError(c.config, n.info, "VM does not support 'cast' from " & $src.kind & " to " & $dst.kind)

proc ldNullOpcode(t: PType): Opcode =
  assert t != nil
  if fitsRegister(t): opcLdNullReg else: opcLdNull

proc cannotEval(c: var ProcCon; n: PNode) {.noinline.} =
  globalError(c.config, n.info, "cannot evaluate at compile time: " &
    n.renderTree)

proc isOwnedBy(a, b: PSym): bool =
  result = false
  var a = a.owner
  while a != nil and a.kind != skModule:
    if a == b: return true
    a = a.owner

proc getOwner(c: ProcCon): PSym =
  result = c.prc.sym
  if result.isNil: result = c.module

proc importcCondVar*(s: PSym): bool {.inline.} =
  # see also importcCond
  if sfImportc in s.flags:
    result = s.kind in {skVar, skLet, skConst}
  else:
    result = false

template needsAdditionalCopy(n): untyped =
  not c.isTemp(d) and not fitsRegister(n.typ)

proc genAdditionalCopy(c: var ProcCon; n: PNode; opc: Opcode;
                       d, idx, value: TRegister) =
  var cc = c.getTemp(n)
  c.gABC(n, whichAsgnOpc(n), cc, value)
  c.gABC(n, opc, d, idx, cc)
  c.freeTemp(cc)

proc preventFalseAlias(c: var ProcCon; n: PNode; opc: Opcode;
                       d, idx, value: TRegister) =
  # opcLdObj et al really means "load address". We sometimes have to create a
  # copy in order to not introduce false aliasing:
  # mylocal = a.b  # needs a copy of the data!
  assert n.typ != nil
  if needsAdditionalCopy(n):
    genAdditionalCopy(c, n, opc, d, idx, value)
  else:
    c.gABC(n, opc, d, idx, value)

proc genAsgn(c: var ProcCon; le, ri: PNode; requiresCopy: bool) =
  case le.kind
  of nkBracketExpr:
    let
      d = c.genx(le[0], {gfNode})
      idx = c.genIndex(le[1], le[0].typ)
      tmp = c.genx(ri)
      collTyp = le[0].typ.skipTypes(abstractVarRange-{tyTypeDesc})
    case collTyp.kind
    of tyString, tyCstring:
      c.preventFalseAlias(le, opcWrStrIdx, d, idx, tmp)
    of tyTuple:
      c.preventFalseAlias(le, opcWrObj, d, int le[1].intVal, tmp)
    else:
      c.preventFalseAlias(le, opcWrArr, d, idx, tmp)
    c.freeTemp(tmp)
    c.freeTemp(idx)
    c.freeTemp(d)
  of nkCheckedFieldExpr:
    var objR: Value = -1
    genCheckedObjAccessAux(c, le, objR, {gfNode})
    let idx = genField(c, le[0][1])
    let tmp = c.genx(ri)
    c.preventFalseAlias(le[0], opcWrObj, objR, idx, tmp)
    c.freeTemp(tmp)
    # c.freeTemp(idx) # BUGFIX, see nkDotExpr
    c.freeTemp(objR)
  of nkDotExpr:
    let d = c.genx(le[0], {gfNode})
    let idx = genField(c, le[1])
    let tmp = c.genx(ri)
    c.preventFalseAlias(le, opcWrObj, d, idx, tmp)
    # c.freeTemp(idx) # BUGFIX: idx is an immediate (field position), not a register
    c.freeTemp(tmp)
    c.freeTemp(d)
  of nkDerefExpr, nkHiddenDeref:
    let d = c.genx(le[0], {gfNode})
    let tmp = c.genx(ri)
    c.preventFalseAlias(le, opcWrDeref, d, 0, tmp)
    c.freeTemp(d)
    c.freeTemp(tmp)
  of nkSym:
    let s = le.sym
    if s.isGlobal:
      withTemp(tmp, le.typ):
        c.gen(le, tmp, {gfNodeAddr})
        let val = c.genx(ri)
        c.preventFalseAlias(le, opcWrDeref, tmp, 0, val)
        c.freeTemp(val)
    else:
      if s.kind == skForVar: c.setSlot s
      internalAssert c.config, s.position > 0 or (s.position == 0 and
                                        s.kind in {skParam, skResult})
      var d: TRegister = s.position + ord(s.kind == skParam)
      assert le.typ != nil
      if needsAdditionalCopy(le) and s.kind in {skResult, skVar, skParam}:
        var cc = c.getTemp(le)
        gen(c, ri, cc)
        c.gABC(le, whichAsgnOpc(le), d, cc)
        c.freeTemp(cc)
      else:
        gen(c, ri, d)
  else:
    let d = c.genx(le, {gfNodeAddr})
    genAsgn(c, d, ri, requiresCopy)
    c.freeTemp(d)

proc genTypeLit(c: var ProcCon; t: PType; d: var Value) =
  var n = newNode(nkType)
  n.typ = t
  genLit(c, n, d)

proc isEmptyBody(n: PNode): bool =
  case n.kind
  of nkStmtList:
    for i in 0..<n.len:
      if not isEmptyBody(n[i]): return false
    result = true
  else:
    result = n.kind in {nkCommentStmt, nkEmpty}

proc importcCond*(c: var ProcCon; s: PSym): bool {.inline.} =
  ## return true to importc `s`, false to execute its body instead (refs #8405)
  result = false
  if sfImportc in s.flags:
    if s.kind in routineKinds:
      return isEmptyBody(getBody(c.graph, s))

proc importcSym(c: var ProcCon; info: TLineInfo; s: PSym) =
  when hasFFI:
    if compiletimeFFI in c.config.features:
      c.globals.add(importcSymbol(c.config, s))
      s.position = c.globals.len
    else:
      localError(c.config, info,
        "VM is not allowed to 'importc' without --experimental:compiletimeFFI")
  else:
    localError(c.config, info,
               "cannot 'importc' variable at compile time; " & s.name.s)

proc getNullValue*(typ: PType, info: TLineInfo; config: ConfigRef): PNode

proc genGlobalInit(c: var ProcCon; n: PNode; s: PSym) =
  c.globals.add(getNullValue(s.typ, n.info, c.config))
  s.position = c.globals.len
  # This is rather hard to support, due to the laziness of the VM code
  # generator. See tests/compile/tmacro2 for why this is necessary:
  #   var decls{.compileTime.}: seq[NimNode] = @[]
  let d = c.getTemp(s)
  c.gABx(n, opcLdGlobal, d, s.position)
  if s.astdef != nil:
    let tmp = c.genx(s.astdef)
    c.genAdditionalCopy(n, opcWrDeref, d, 0, tmp)
    c.freeTemp(d)
    c.freeTemp(tmp)

template needsRegLoad(): untyped =
  {gfNode, gfNodeAddr} * flags == {} and
    fitsRegister(n.typ.skipTypes({tyVar, tyLent, tyStatic}))

proc genArrAccessOpcode(c: var ProcCon; n: PNode; d: var Value; opc: Opcode;
                        flags: GenFlags) =
  let a = c.genx(n[0], flags)
  let b = c.genIndex(n[1], n[0].typ)
  if isEmpty(d): d = c.getTemp(n)
  if opc in {opcLdArrAddr, opcLdStrIdxAddr} and gfNodeAddr in flags:
    c.gABC(n, opc, d, a, b)
  elif needsRegLoad():
    var cc = c.getTemp(n)
    c.gABC(n, opc, cc, a, b)
    c.gABC(n, opcNodeToReg, d, cc)
    c.freeTemp(cc)
  else:
    #message(c.config, n.info, warnUser, "argh")
    #echo "FLAGS ", flags, " ", fitsRegister(n.typ), " ", typeToString(n.typ)
    c.gABC(n, opc, d, a, b)
  c.freeTemp(a)
  c.freeTemp(b)

proc genObjAccessAux(c: var ProcCon; n: PNode; a, b: int, d: var Value; flags: GenFlags) =
  if isEmpty(d): d = c.getTemp(n)
  if {gfNodeAddr} * flags != {}:
    c.gABC(n, opcLdObjAddr, d, a, b)
  elif needsRegLoad():
    var cc = c.getTemp(n)
    c.gABC(n, opcLdObj, cc, a, b)
    c.gABC(n, opcNodeToReg, d, cc)
    c.freeTemp(cc)
  else:
    c.gABC(n, opcLdObj, d, a, b)
  c.freeTemp(a)

proc genObjAccess(c: var ProcCon; n: PNode; d: var Value; flags: GenFlags) =
  genObjAccessAux(c, n, c.genx(n[0], flags), genField(c, n[1]), d, flags)

proc genCheckedObjAccessAux(c: var ProcCon; n: PNode; d: var Value; flags: GenFlags) =
  internalAssert c.config, n.kind == nkCheckedFieldExpr
  # nkDotExpr to access the requested field
  let accessExpr = n[0]
  # nkCall to check if the discriminant is valid
  var checkExpr = n[1]

  let negCheck = checkExpr[0].sym.magic == mNot
  if negCheck:
    checkExpr = checkExpr[^1]

  # Discriminant symbol
  let disc = checkExpr[2]
  internalAssert c.config, disc.sym.kind == skField

  # Load the object in `d`
  c.gen(accessExpr[0], d, flags)
  # Load the discriminant
  var discVal = c.getTemp(disc)
  c.gABC(n, opcLdObj, discVal, d, genField(c, disc))
  # Check if its value is contained in the supplied set
  let setLit = c.genx(checkExpr[1])
  var rs = c.getTemp(getSysType(c.graph, n.info, tyBool))
  c.gABC(n, opcContainsSet, rs, setLit, discVal)
  c.freeTemp(setLit)
  # If the check fails let the user know
  let lab1 = c.xjmp(n, if negCheck: opcFJmp else: opcTJmp, rs)
  c.freeTemp(rs)
  let strType = getSysType(c.graph, n.info, tyString)
  var msgReg: Value = c.getTemp(strType)
  let fieldName = $accessExpr[1]
  let msg = genFieldDefect(c.config, fieldName, disc.sym)
  let strLit = newStrNode(msg, accessExpr[1].info)
  strLit.typ = strType
  c.genLit(strLit, msgReg)
  c.gABC(n, opcInvalidField, msgReg, discVal)
  c.freeTemp(discVal)
  c.freeTemp(msgReg)
  c.patch(lab1)

proc genCheckedObjAccess(c: var ProcCon; n: PNode; d: var Value; flags: GenFlags) =
  var objR: Value = -1
  genCheckedObjAccessAux(c, n, objR, flags)

  let accessExpr = n[0]
  # Field symbol
  var field = accessExpr[1]
  internalAssert c.config, field.sym.kind == skField

  # Load the content now
  if isEmpty(d): d = c.getTemp(n)
  let fieldPos = genField(c, field)

  if {gfNodeAddr} * flags != {}:
    c.gABC(n, opcLdObjAddr, d, objR, fieldPos)
  elif needsRegLoad():
    var cc = c.getTemp(accessExpr)
    c.gABC(n, opcLdObj, cc, objR, fieldPos)
    c.gABC(n, opcNodeToReg, d, cc)
    c.freeTemp(cc)
  else:
    c.gABC(n, opcLdObj, d, objR, fieldPos)

  c.freeTemp(objR)

proc genArrAccess(c: var ProcCon; n: PNode; d: var Value; flags: GenFlags) =
  let arrayType = n[0].typ.skipTypes(abstractVarRange-{tyTypeDesc}).kind
  case arrayType
  of tyString, tyCstring:
    let opc = if gfNodeAddr in flags: opcLdStrIdxAddr else: opcLdStrIdx
    genArrAccessOpcode(c, n, d, opc, flags)
  of tyTuple:
    c.genObjAccessAux(n, c.genx(n[0], flags), int n[1].intVal, d, flags)
  of tyTypeDesc:
    c.genTypeLit(n.typ, d)
  else:
    let opc = if gfNodeAddr in flags: opcLdArrAddr else: opcLdArr
    genArrAccessOpcode(c, n, d, opc, flags)

proc getNullValueAux(t: PType; obj: PNode, result: PNode; config: ConfigRef; currPosition: var int) =
  if t != nil and t.len > 0 and t[0] != nil:
    let b = skipTypes(t[0], skipPtrs)
    getNullValueAux(b, b.n, result, config, currPosition)
  case obj.kind
  of nkRecList:
    for i in 0..<obj.len: getNullValueAux(nil, obj[i], result, config, currPosition)
  of nkRecCase:
    getNullValueAux(nil, obj[0], result, config, currPosition)
    for i in 1..<obj.len:
      getNullValueAux(nil, lastSon(obj[i]), result, config, currPosition)
  of nkSym:
    let field = newNodeI(nkExprColonExpr, result.info)
    field.add(obj)
    let value = getNullValue(obj.sym.typ, result.info, config)
    value.flags.incl nfSkipFieldChecking
    field.add(value)
    result.add field
    doAssert obj.sym.position == currPosition
    inc currPosition
  else: globalError(config, result.info, "cannot create null element for: " & $obj)

proc getNullValue(typ: PType, info: TLineInfo; config: ConfigRef): PNode =
  var t = skipTypes(typ, abstractRange+{tyStatic, tyOwned}-{tyTypeDesc})
  case t.kind
  of tyBool, tyEnum, tyChar, tyInt..tyInt64:
    result = newNodeIT(nkIntLit, info, t)
  of tyUInt..tyUInt64:
    result = newNodeIT(nkUIntLit, info, t)
  of tyFloat..tyFloat128:
    result = newNodeIT(nkFloatLit, info, t)
  of tyString:
    result = newNodeIT(nkStrLit, info, t)
    result.strVal = ""
  of tyCstring, tyVar, tyLent, tyPointer, tyPtr, tyUntyped,
     tyTyped, tyTypeDesc, tyRef, tyNil:
    result = newNodeIT(nkNilLit, info, t)
  of tyProc:
    if t.callConv != ccClosure:
      result = newNodeIT(nkNilLit, info, t)
    else:
      result = newNodeIT(nkTupleConstr, info, t)
      result.add(newNodeIT(nkNilLit, info, t))
      result.add(newNodeIT(nkNilLit, info, t))
  of tyObject:
    result = newNodeIT(nkObjConstr, info, t)
    result.add(newNodeIT(nkEmpty, info, t))
    # initialize inherited fields, and all in the correct order:
    var currPosition = 0
    getNullValueAux(t, t.n, result, config, currPosition)
  of tyArray:
    result = newNodeIT(nkBracket, info, t)
    for i in 0..<toInt(lengthOrd(config, t)):
      result.add getNullValue(elemType(t), info, config)
  of tyTuple:
    result = newNodeIT(nkTupleConstr, info, t)
    for i in 0..<t.len:
      result.add getNullValue(t[i], info, config)
  of tySet:
    result = newNodeIT(nkCurly, info, t)
  of tySequence, tyOpenArray:
    result = newNodeIT(nkBracket, info, t)
  else:
    globalError(config, info, "cannot create null element for: " & $t.kind)
    result = newNodeI(nkEmpty, info)

proc genVarSection(c: var ProcCon; n: PNode) =
  for a in n:
    if a.kind == nkCommentStmt: continue
    #assert(a[0].kind == nkSym) can happen for transformed vars
    if a.kind == nkVarTuple:
      for i in 0..<a.len-2:
        if a[i].kind == nkSym:
          if not a[i].sym.isGlobal: setSlot(c, a[i].sym)
      c.gen(lowerTupleUnpacking(c.graph, a, c.idgen, c.getOwner))
    elif a[0].kind == nkSym:
      let s = a[0].sym
      if s.isGlobal:
        let runtimeAccessToCompileTime = c.mode == emRepl and
              sfCompileTime in s.flags and s.position > 0
        if s.position == 0:
          if importcCond(c, s): c.importcSym(a.info, s)
          else:
            let sa = getNullValue(s.typ, a.info, c.config)
            #if s.ast.isNil: getNullValue(s.typ, a.info)
            #else: s.ast
            assert sa.kind != nkCall
            c.globals.add(sa)
            s.position = c.globals.len
        if runtimeAccessToCompileTime:
          discard
        elif a[2].kind != nkEmpty:
          let tmp = c.genx(a[0], {gfNodeAddr})
          let val = c.genx(a[2])
          c.genAdditionalCopy(a[2], opcWrDeref, tmp, 0, val)
          c.freeTemp(val)
          c.freeTemp(tmp)
        elif not importcCondVar(s) and not (s.typ.kind == tyProc and s.typ.callConv == ccClosure) and
                sfPure notin s.flags: # fixes #10938
          # there is a pre-existing issue with closure types in VM
          # if `(var s: proc () = default(proc ()); doAssert s == nil)` works for you;
          # you might remove the second condition.
          # the problem is that closure types are tuples in VM, but the types of its children
          # shouldn't have the same type as closure types.
          let tmp = c.genx(a[0], {gfNodeAddr})
          let sa = getNullValue(s.typ, a.info, c.config)
          let val = c.genx(sa)
          c.genAdditionalCopy(sa, opcWrDeref, tmp, 0, val)
          c.freeTemp(val)
          c.freeTemp(tmp)
      else:
        setSlot(c, s)
        if a[2].kind == nkEmpty:
          c.gABx(a, ldNullOpcode(s.typ), s.position, c.genType(s.typ))
        else:
          assert s.typ != nil
          if not fitsRegister(s.typ):
            c.gABx(a, ldNullOpcode(s.typ), s.position, c.genType(s.typ))
          let le = a[0]
          assert le.typ != nil
          if not fitsRegister(le.typ) and s.kind in {skResult, skVar, skParam}:
            var cc = c.getTemp(le)
            gen(c, a[2], cc)
            c.gABC(le, whichAsgnOpc(le), s.position.TRegister, cc)
            c.freeTemp(cc)
          else:
            gen(c, a[2], s.position.TRegister)
    else:
      # assign to a[0]; happens for closures
      if a[2].kind == nkEmpty:
        let tmp = genx(c, a[0])
        c.gABx(a, ldNullOpcode(a[0].typ), tmp, c.genType(a[0].typ))
        c.freeTemp(tmp)
      else:
        genAsgn(c, a[0], a[2], true)

proc genArrayConstr(c: var ProcCon; n: PNode, d: var Value) =
  if isEmpty(d): d = c.getTemp(n)
  c.gABx(n, opcLdNull, d, c.genType(n.typ))

  let intType = getSysType(c.graph, n.info, tyInt)
  let seqType = n.typ.skipTypes(abstractVar-{tyTypeDesc})
  if seqType.kind == tySequence:
    var tmp = c.getTemp(intType)
    c.gABx(n, opcLdImmInt, tmp, n.len)
    c.gABx(n, opcNewSeq, d, c.genType(seqType))
    c.gABx(n, opcNewSeq, tmp, 0)
    c.freeTemp(tmp)

  if n.len > 0:
    var tmp = getTemp(c, intType)
    c.gABx(n, opcLdNullReg, tmp, c.genType(intType))
    for x in n:
      let a = c.genx(x)
      c.preventFalseAlias(n, opcWrArr, d, tmp, a)
      c.gABI(n, opcAddImmInt, tmp, tmp, 1)
      c.freeTemp(a)
    c.freeTemp(tmp)

proc genSetConstr(c: var ProcCon; n: PNode, d: var Value) =
  if isEmpty(d): d = c.getTemp(n)
  c.gABx(n, opcLdNull, d, c.genType(n.typ))
  for x in n:
    if x.kind == nkRange:
      let a = c.genx(x[0])
      let b = c.genx(x[1])
      c.gABC(n, opcInclRange, d, a, b)
      c.freeTemp(b)
      c.freeTemp(a)
    else:
      let a = c.genx(x)
      c.gABC(n, opcIncl, d, a)
      c.freeTemp(a)

proc genObjConstr(c: var ProcCon; n: PNode, d: var Value) =
  if isEmpty(d): d = c.getTemp(n)
  let t = n.typ.skipTypes(abstractRange+{tyOwned}-{tyTypeDesc})
  if t.kind == tyRef:
    c.gABx(n, opcNew, d, c.genType(t[0]))
  else:
    c.gABx(n, opcLdNull, d, c.genType(n.typ))
  for i in 1..<n.len:
    let it = n[i]
    if it.kind == nkExprColonExpr and it[0].kind == nkSym:
      let idx = genField(c, it[0])
      let tmp = c.genx(it[1])
      c.preventFalseAlias(it[1], opcWrObj,
                          d, idx, tmp)
      c.freeTemp(tmp)
    else:
      globalError(c.config, n.info, "invalid object constructor")

proc genTupleConstr(c: var ProcCon; n: PNode, d: var Value) =
  if isEmpty(d): d = c.getTemp(n)
  if n.typ.kind != tyTypeDesc:
    c.gABx(n, opcLdNull, d, c.genType(n.typ))
    # XXX x = (x.old, 22)  produces wrong code ... stupid self assignments
    for i in 0..<n.len:
      let it = n[i]
      if it.kind == nkExprColonExpr:
        let idx = genField(c, it[0])
        let tmp = c.genx(it[1])
        c.preventFalseAlias(it[1], opcWrObj,
                            d, idx, tmp)
        c.freeTemp(tmp)
      else:
        let tmp = c.genx(it)
        c.preventFalseAlias(it, opcWrObj, d, i.TRegister, tmp)
        c.freeTemp(tmp)

proc genProc*(c: var ProcCon; s: PSym): int

proc toKey(s: PSym): string =
  result = ""
  var s = s
  while s != nil:
    result.add s.name.s
    if s.owner != nil:
      if sfFromGeneric in s.flags:
        s = s.instantiatedFrom.owner
      else:
        s = s.owner
      result.add "."
    else:
      break

proc procIsCallback(c: var ProcCon; s: PSym): bool =
  if s.offset < -1: return true
  let key = toKey(s)
  if c.callbackIndex.contains(key):
    let index = c.callbackIndex[key]
    doAssert s.offset == -1
    s.offset = -2'i32 - index.int32
    result = true
  else:
    result = false
]#

proc genAsgn(c: var ProcCon; n: PNode) =
  var d = c.genx(n[0])
  c.gen n[1], d

proc convStrToCStr(c: var ProcCon; n: PNode; d: var Value) =
  genUnaryCp(c, n, d, "nimToCStringConv", argAt = 0)

proc convCStrToStr(c: var ProcCon; n: PNode; d: var Value) =
  genUnaryCp(c, n, d, "cstrToNimstr", argAt = 0)

proc irModule(c: var ProcCon; owner: PSym): string =
  #if owner == c.m.module: "" else:
  customPath(toFullPath(c.config, owner.info))

proc genRdVar(c: var ProcCon; n: PNode; d: var Value; flags: GenFlags) =
  let info = toLineInfo(c, n.info)
  let s = n.sym
  if ast.originatingModule(s) != c.m.module:
    template body(target) =
      build target, info, ModuleSymUse:
        target.addStrVal c.m.strings, info, irModule(c, ast.originatingModule(s))
        target.addImmediateVal info, s.itemId.item.int

    valueIntoDest c, info, d, s.typ, body
  else:
    template body(target) =
      target.addSymUse info, SymId(s.itemId.item)
    valueIntoDest c, info, d, s.typ, body

proc genSym(c: var ProcCon; n: PNode; d: var Value; flags: GenFlags = {}) =
  let s = n.sym
  case s.kind
  of skVar, skForVar, skTemp, skLet, skResult, skParam, skConst:
    genRdVar(c, n, d, flags)
  of skProc, skFunc, skConverter, skMethod, skIterator:
    if ast.originatingModule(s) == c.m.module:
      # anon and generic procs have no AST so we need to remember not to forget
      # to emit these:
      if not c.m.pendingProcs.hasKey(s.itemId):
        c.m.pendingProcs[s.itemId] = s
    genRdVar(c, n, d, flags)
  else:
    localError(c.config, n.info, "cannot generate code for: " & s.name.s)

proc genNumericLit(c: var ProcCon; n: PNode; d: var Value) =
  let info = toLineInfo(c, n.info)
  template body(target) =
    target.addIntVal c.m.integers, info, typeToIr(c.m.types, n.typ), n.intVal
  valueIntoDest c, info, d, n.typ, body

proc genStringLit(c: var ProcCon; n: PNode; d: var Value) =
  let info = toLineInfo(c, n.info)
  template body(target) =
    target.addStrVal c.m.strings, info, n.strVal
  valueIntoDest c, info, d, n.typ, body

proc genNilLit(c: var ProcCon; n: PNode; d: var Value) =
  let info = toLineInfo(c, n.info)
  template body(target) =
    target.addNilVal info, typeToIr(c.m.types, n.typ)
  valueIntoDest c, info, d, n.typ, body

proc genRangeCheck(c: var ProcCon; n: PNode; d: var Value) =
  # XXX to implement properly
  gen c, n[0], d

proc gen(c: var ProcCon; n: PNode; d: var Value; flags: GenFlags = {}) =
  when defined(nimCompilerStacktraceHints):
    setFrameMsg c.config$n.info & " " & $n.kind & " " & $flags
  case n.kind
  of nkSym: genSym(c, n, d, flags)
  of nkCallKinds:
    if n[0].kind == nkSym:
      let s = n[0].sym
      if s.magic != mNone:
        genMagic(c, n, d, s.magic)
      elif s.kind == skMethod:
        localError(c.config, n.info, "cannot call method " & s.name.s &
          " at compile time")
      else:
        genCall(c, n, d)
        clearDest(c, n, d)
    else:
      genCall(c, n, d)
      clearDest(c, n, d)
  of nkCharLit..nkInt64Lit, nkUIntLit..nkUInt64Lit:
    genNumericLit(c, n, d)
  of nkStrLit..nkTripleStrLit:
    genStringLit(c, n, d)
  of nkNilLit:
    if not n.typ.isEmptyType: genNilLit(c, n, d)
    else: unused(c, n, d)
  of nkAsgn, nkFastAsgn, nkSinkAsgn:
    unused(c, n, d)
    genAsgn(c, n)
  of nkDotExpr:
    #genObjAccess(c, n, d, flags)
    discard "XXX"
  of nkCheckedFieldExpr:
    #genCheckedObjAccess(c, n, d, flags)
    discard "XXX"
  of nkBracketExpr:
    #genArrAccess(c, n, d, flags)
    discard "XXX"
  of nkDerefExpr, nkHiddenDeref: genDeref(c, n, d, flags)
  of nkAddr, nkHiddenAddr: genAddr(c, n, d, flags)
  of nkIfStmt, nkIfExpr: genIf(c, n, d)
  of nkWhenStmt:
    # This is "when nimvm" node. Chose the first branch.
    gen(c, n[0][1], d)
  of nkCaseStmt: genCase(c, n, d)
  of nkWhileStmt:
    unused(c, n, d)
    genWhile(c, n)
  of nkBlockExpr, nkBlockStmt: genBlock(c, n, d)
  of nkReturnStmt: genReturn(c, n)
  of nkRaiseStmt: genRaise(c, n)
  of nkBreakStmt: genBreak(c, n)
  of nkTryStmt, nkHiddenTryStmt: genTry(c, n, d)
  of nkStmtList:
    #unused(c, n, d)
    # XXX Fix this bug properly, lexim triggers it
    for x in n: gen(c, x)
  of nkStmtListExpr:
    for i in 0..<n.len-1: gen(c, n[i])
    gen(c, n[^1], d, flags)
  of nkPragmaBlock:
    gen(c, n.lastSon, d, flags)
  of nkDiscardStmt:
    unused(c, n, d)
    gen(c, n[0], d)
  of nkHiddenStdConv, nkHiddenSubConv, nkConv:
    #genConv(c, n, n[1], d)
    discard "XXX"
  of nkObjDownConv:
    #genConv(c, n, n[0], d)
    discard "XXX"
  of nkObjUpConv:
    #genConv(c, n, n[0], d)
    discard "XXX"
  of nkVarSection, nkLetSection:
    unused(c, n, d)
    #genVarSection(c, n)
    discard "XXX"
  of nkLambdaKinds:
    #let s = n[namePos].sym
    #discard genProc(c, s)
    gen(c, newSymNode(n[namePos].sym), d)
  of nkChckRangeF, nkChckRange64, nkChckRange:
    genRangeCheck(c, n, d)
  of nkEmpty, nkCommentStmt, nkTypeSection, nkConstSection, nkPragma,
     nkTemplateDef, nkIncludeStmt, nkImportStmt, nkFromStmt, nkExportStmt,
     nkMixinStmt, nkBindStmt, declarativeDefs, nkMacroDef:
    unused(c, n, d)
  of nkStringToCString: convStrToCStr(c, n, d)
  of nkCStringToString: convCStrToStr(c, n, d)
  of nkBracket:
    #genArrayConstr(c, n, d)
    discard "XXX"
  of nkCurly:
    #genSetConstr(c, n, d)
    discard "XXX"
  of nkObjConstr:
    #genObjConstr(c, n, d)
    discard "XXX"
  of nkPar, nkClosure, nkTupleConstr:
    #genTupleConstr(c, n, d)
    discard "XXX"
  of nkCast:
    #genCast(c, n, d)
    discard "XXX"
  of nkComesFrom:
    discard "XXX to implement for better stack traces"
  else:
    localError(c.config, n.info, "cannot generate IR code for " & $n)

proc genStmt*(c: var ProcCon; n: PNode): int =
  result = c.code.len
  var d = default(Value)
  c.gen(n, d)
  unused c, n, d

proc genExpr*(c: var ProcCon; n: PNode, requiresValue = true): int =
  result = c.code.len
  var d = default(Value)
  c.gen(n, d)
  if isEmpty d:
    if requiresValue:
      globalError(c.config, n.info, "VM problem: d register is not set")

when false:
  proc genParams(c: var ProcCon; params: PNode) =
    # res.sym.position is already 0
    setLen(c.prc.regInfo, max(params.len, 1))
    c.prc.regInfo[0] = (inUse: true, kind: slotFixedVar)
    for i in 1..<params.len:
      c.prc.regInfo[i] = (inUse: true, kind: slotFixedLet)
