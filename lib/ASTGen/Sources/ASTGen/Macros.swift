import SwiftDiagnostics
import SwiftOperators
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacros

extension SyntaxProtocol {
  func token(at position: AbsolutePosition) -> TokenSyntax? {
    // If the position isn't within this node at all, return early.
    guard position >= self.position && position < self.endPosition else {
      return nil
    }

    // If we are a token syntax, that's it!
    if let token = Syntax(self).as(TokenSyntax.self) {
      return token
    }

    // Otherwise, it must be one of our children.
    for child in children(viewMode: .sourceAccurate) {
      if let token = child.token(at: position) {
        return token
      }
    }
    fatalError("Children of syntax node do not cover all positions in it")
  }
}

/// Describes a macro that has been "exported" to the C++ part of the
/// compiler, with enough information to interface with the C++ layer.
struct ExportedMacro {
  var macro: Macro.Type
}

enum MacroRole: UInt8 {
  case Expression = 0x01
  case FreestandingDeclaration = 0x02
  case Accessor = 0x04
  case MemberAttribute = 0x08
  case Member = 0x10
}

/// Resolve a reference to type metadata into a macro, if posible.
///
/// Returns an unmanaged pointer to an ExportedMacro instance that describes
/// the specified macro. If there is no macro with the given name, produces
/// nil.
@_cdecl("swift_ASTGen_resolveMacroType")
public func resolveMacroType(
  macroTypePtr: UnsafePointer<UInt8>
) -> UnsafeRawPointer? {
  let macroType = unsafeBitCast(macroTypePtr, to: Any.Type.self)

  guard let macro = macroType as? Macro.Type else {
    return nil
  }

  // Allocate and initialize the exported macro.
  let exportedPtr = UnsafeMutablePointer<ExportedMacro>.allocate(capacity: 1)
  exportedPtr.initialize(to: .init(macro: macro))
  return UnsafeRawPointer(exportedPtr)
}

/// Destroys the given macro.
@_cdecl("swift_ASTGen_destroyMacro")
public func destroyMacro(
  macroPtr: UnsafeMutablePointer<UInt8>
) {
  macroPtr.withMemoryRebound(to: ExportedMacro.self, capacity: 1) { macro in
    macro.deinitialize(count: 1)
    macro.deallocate()
  }
}

/// Allocate a copy of the given string as a UTF-8 string.
func allocateUTF8String(
  _ string: String,
  nullTerminated: Bool = false
) -> (UnsafePointer<UInt8>, Int) {
  var string = string
  return string.withUTF8 { utf8 in
    let capacity = utf8.count + (nullTerminated ? 1 : 0)
    let ptr = UnsafeMutablePointer<UInt8>.allocate(
      capacity: capacity
    )
    if let baseAddress = utf8.baseAddress {
      ptr.initialize(from: baseAddress, count: utf8.count)
    }

    if nullTerminated {
      ptr[utf8.count] = 0
    }

    return (UnsafePointer<UInt8>(ptr), utf8.count)
  }
}

/// Diagnostic message used for thrown errors.
fileprivate struct ThrownErrorDiagnostic: DiagnosticMessage {
  let message: String

  var severity: DiagnosticSeverity { .error }

  var diagnosticID: MessageID {
    .init(domain: "SwiftSyntaxMacros", id: "ThrownErrorDiagnostic")
  }
}

@_cdecl("swift_ASTGen_evaluateMacro")
@usableFromInline
func evaluateMacro(
  diagEnginePtr: UnsafeMutablePointer<UInt8>,
  macroPtr: UnsafeRawPointer,
  sourceFilePtr: UnsafeRawPointer,
  sourceLocationPtr: UnsafePointer<UInt8>?,
  expandedSourcePointer: UnsafeMutablePointer<UnsafePointer<UInt8>?>,
  expandedSourceLength: UnsafeMutablePointer<Int>
) -> Int {
  // We didn't expand anything so far.
  expandedSourcePointer.pointee = nil
  expandedSourceLength.pointee = 0

  guard let sourceLocationPtr = sourceLocationPtr else {
    print("NULL source location")
    return -1
  }

  let sourceFilePtr = sourceFilePtr.bindMemory(to: ExportedSourceFile.self, capacity: 1)
  // Find the offset.
  let buffer = sourceFilePtr.pointee.buffer
  let offset = sourceLocationPtr - buffer.baseAddress!
  if offset < 0 || offset >= buffer.count {
    print("source location isn't inside this buffer")
    return -1
  }

  let sf = sourceFilePtr.pointee.syntax
  guard let token = sf.token(at: AbsolutePosition(utf8Offset: offset)) else {
    print("couldn't find token at offset \(offset)")
    return -1
  }

  // Create a source manager. This should probably persist and be given to us.
  let sourceManager = SourceManager(cxxDiagnosticEngine: diagEnginePtr)
  sourceManager.insert(sourceFilePtr)

  let context = sourceManager.createMacroExpansionContext()

  guard let parentSyntax = token.parent else {
    print("not on a macro expansion node: \(token.recursiveDescription)")
    return -1
  }

  let macroPtr = macroPtr.bindMemory(to: ExportedMacro.self, capacity: 1)

  let macroName: String
  let evaluatedSyntax: Syntax
  do {
    switch macroPtr.pointee.macro {
    // Handle expression macro.
    case let exprMacro as ExpressionMacro.Type:
      guard let parentExpansion = parentSyntax.asProtocol(
        FreestandingMacroExpansionSyntax.self
      ) else {
        print("not on a macro expansion node: \(parentSyntax.recursiveDescription)")
        return -1
      }

      macroName = parentExpansion.macro.text
      evaluatedSyntax = Syntax(
        try exprMacro.expansion(
          of: sourceManager.detach(
            parentExpansion, in: context,
            foldingWith: OperatorTable.standardOperators
          ),
          in: context
        )
      )

    // Handle expression macro. The resulting decls are wrapped in a `CodeBlockItemListSyntax`.
    case let declMacro as DeclarationMacro.Type:
      guard let parentExpansion = parentSyntax.as(MacroExpansionDeclSyntax.self) else {
        print("not on a macro expansion node: \(token.recursiveDescription)")
        return -1
      }
      let decls = try declMacro.expansion(
        of: sourceManager.detach(parentExpansion, in: context),
        in: context
      )
      macroName = parentExpansion.macro.text
      evaluatedSyntax = Syntax(CodeBlockItemListSyntax(
        decls.map { CodeBlockItemSyntax(item: .decl($0)) }))

    default:
      print("not an expression macro or a freestanding declaration macro")
      return -1
    }
  } catch {
    // Record the error
    context.diagnose(
      Diagnostic(
        node: parentSyntax,
        message: ThrownErrorDiagnostic(message: String(describing: error))
      )
    )
    return -1
  }

  // Emit diagnostics accumulated in the context.
  for diag in context.diagnostics {
    sourceManager.diagnose(
      diagnostic: diag,
      messageSuffix: " (from macro '\(macroName)')"
    )
  }

  var evaluatedSyntaxStr = evaluatedSyntax.trimmedDescription
  evaluatedSyntaxStr.withUTF8 { utf8 in
    let evaluatedResultPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: utf8.count + 1)
    if let baseAddress = utf8.baseAddress {
      evaluatedResultPtr.initialize(from: baseAddress, count: utf8.count)
    }
    evaluatedResultPtr[utf8.count] = 0

    expandedSourcePointer.pointee = UnsafePointer(evaluatedResultPtr)
    expandedSourceLength.pointee = utf8.count
  }

  return 0
}

/// Retrieve a syntax node in the given source file, with the given type.
private func findSyntaxNodeInSourceFile<Node: SyntaxProtocol>(
  sourceFilePtr: UnsafeRawPointer,
  sourceLocationPtr: UnsafePointer<UInt8>?,
  type: Node.Type
) -> Node? {
  guard let sourceLocationPtr = sourceLocationPtr else {
    return nil
  }

  let sourceFilePtr = sourceFilePtr.bindMemory(
    to: ExportedSourceFile.self, capacity: 1
  )

  // Find the offset.
  let buffer = sourceFilePtr.pointee.buffer
  let offset = sourceLocationPtr - buffer.baseAddress!
  if offset < 0 || offset >= buffer.count {
    print("source location isn't inside this buffer")
    return nil
  }

  // Find the token at that offset.
  let sf = sourceFilePtr.pointee.syntax
  guard let token = sf.token(at: AbsolutePosition(utf8Offset: offset)) else {
    print("couldn't find token at offset \(offset)")
    return nil
  }

  // Dig out its parent.
  guard let parentSyntax = token.parent else {
    print("not on a macro expansion node: \(token.recursiveDescription)")
    return nil
  }

  return parentSyntax.as(type)
}

@_cdecl("swift_ASTGen_expandAttachedMacro")
@usableFromInline
func expandAttachedMacro(
  diagEnginePtr: UnsafeMutablePointer<UInt8>,
  macroPtr: UnsafeRawPointer,
  rawMacroRole: UInt8,
  customAttrSourceFilePtr: UnsafeRawPointer,
  customAttrSourceLocPointer: UnsafePointer<UInt8>?,
  declarationSourceFilePtr: UnsafeRawPointer,
  attachedTo declarationSourceLocPointer: UnsafePointer<UInt8>?,
  parentDeclSourceFilePtr: UnsafeRawPointer,
  parentDeclSourceLocPointer: UnsafePointer<UInt8>?,
  expandedSourcePointer: UnsafeMutablePointer<UnsafePointer<UInt8>?>,
  expandedSourceLength: UnsafeMutablePointer<Int>
) -> Int {
  // We didn't expand anything so far.
  expandedSourcePointer.pointee = nil
  expandedSourceLength.pointee = 0

  // Dig out the custom attribute for the attached macro declarations.
  guard let customAttrNode = findSyntaxNodeInSourceFile(
    sourceFilePtr: customAttrSourceFilePtr,
    sourceLocationPtr: customAttrSourceLocPointer,
    type: AttributeSyntax.self
  ) else {
    return 1
  }

  // Dig out the node for the declaration to which the custom attribute is
  // attached.
  guard let declarationNode = findSyntaxNodeInSourceFile(
    sourceFilePtr: declarationSourceFilePtr,
    sourceLocationPtr: declarationSourceLocPointer,
    type: DeclSyntax.self
  ) else {
    return 1
  }

  // Get the macro.
  let macroPtr = macroPtr.bindMemory(to: ExportedMacro.self, capacity: 1)
  let macro = macroPtr.pointee.macro
  let macroRole = MacroRole(rawValue: rawMacroRole)

  let attributeSourceFile = customAttrSourceFilePtr.bindMemory(
    to: ExportedSourceFile.self, capacity: 1
  )
  let declarationSourceFilePtr = declarationSourceFilePtr.bindMemory(
    to: ExportedSourceFile.self, capacity: 1
  )

  // Create a source manager covering the files we know about.
  let sourceManager = SourceManager(cxxDiagnosticEngine: diagEnginePtr)
  sourceManager.insert(attributeSourceFile)
  sourceManager.insert(declarationSourceFilePtr)

  // Create an expansion context
  let context = sourceManager.createMacroExpansionContext()

  let macroName = customAttrNode.attributeName.description
  var evaluatedSyntaxStr: String
  do {
    switch (macro, macroRole) {
    case (let attachedMacro as AccessorMacro.Type, .Accessor):
      let accessors = try attachedMacro.expansion(
        of: context.detach(customAttrNode),
        providingAccessorsOf: context.detach(declarationNode),
        in: context
      )

      // Form a buffer of accessor declarations to return to the caller.
      evaluatedSyntaxStr = accessors.map {
        $0.trimmedDescription
      }.joined(separator: "\n\n")

    case (let attachedMacro as MemberAttributeMacro.Type, .MemberAttribute):
      // Dig out the node for the parent declaration of the to-expand
      // declaration. Only member attribute macros need this.
      guard let parentDeclNode = findSyntaxNodeInSourceFile(
        sourceFilePtr: parentDeclSourceFilePtr,
        sourceLocationPtr: parentDeclSourceLocPointer,
        type: DeclSyntax.self
      ),
            let parentDeclGroup = parentDeclNode.asProtocol(DeclGroupSyntax.self)
      else {
        return 1
      }

      let attributes = try attachedMacro.expansion(
        of: context.detach(customAttrNode),
        attachedTo: context.detach(parentDeclGroup),
        providingAttributesFor: context.detach(declarationNode),
        in: context
      )

      // Form a buffer containing an attribute list to return to the caller.
      evaluatedSyntaxStr = attributes.map {
        $0.trimmedDescription
      }.joined(separator: " ")

    case (let attachedMacro as MemberMacro.Type, .Member):
      guard let declGroup = declarationNode.asProtocol(DeclGroupSyntax.self)
      else {
        return 1
      }

      let members = try attachedMacro.expansion(
        of: context.detach(customAttrNode),
        providingMembersOf: context.detach(declGroup),
        in: context
      )

      // Form a buffer of member declarations to return to the caller.
      evaluatedSyntaxStr = members.map {
        $0.trimmedDescription
      }.joined(separator: "\n\n")

    default:
      print("\(macroPtr) does not conform to any known attached macro protocol")
      return 1
    }
  } catch {
    // Record the error
    // FIXME: Need to decide where to diagnose the error:
    context.diagnose(
      Diagnostic(
        node: Syntax(declarationNode),
        message: ThrownErrorDiagnostic(message: String(describing: error))
      )
    )

    return 1
  }

  // Emit diagnostics accumulated in the context.
  for diag in context.diagnostics {
    sourceManager.diagnose(
      diagnostic: diag,
      messageSuffix: " (from macro '\(macroName)')"
    )
  }

  // Form the result buffer for our caller.
  evaluatedSyntaxStr.withUTF8 { utf8 in
    let evaluatedResultPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: utf8.count + 1)
    if let baseAddress = utf8.baseAddress {
      evaluatedResultPtr.initialize(from: baseAddress, count: utf8.count)
    }
    evaluatedResultPtr[utf8.count] = 0

    expandedSourcePointer.pointee = UnsafePointer(evaluatedResultPtr)
    expandedSourceLength.pointee = utf8.count
  }

  return 0
}
