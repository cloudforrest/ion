{traverse} = require './traverseAst'
basicTraverse = require('./traverse').traverse
{addStatement,forEachDestructuringAssignment} = require './astFunctions'
nodes = require './nodes'
ion = require '../'

undefinedExpression = Object.freeze
    type: 'UnaryExpression'
    argument:
        type: 'Literal'
        value: 0
    operator: 'void'
    prefix: true
nullExpression = Object.freeze
    type: 'Literal'
    value: null
ionExpression = Object.freeze
    type: 'Identifier'
    name: 'ion'
thisExpression = Object.freeze
    type: 'ThisExpression'

getPathExpression = (path) ->
    steps = path.split '.'

    if steps[0] is 'this'
        result =
            type: 'ThisExpression'
    else
        result =
            type: 'Identifier'
            name: steps[0]
    for step, i in steps when i > 0
        result =
            type: 'MemberExpression'
            object: result
            property:
                type: 'Identifier'
                name: step
    return result

isFunctionNode = (node) -> nodes[node?.type]?.isFunction ? false

nodeToLiteral = (object) ->
    node = null
    if object?.toLiteral?
        node = object?.toLiteral()
    else if Array.isArray object
        node =
            type: 'ArrayExpression'
            elements: (nodeToLiteral item for item in object)
    else if object?.constructor is Object
        node =
            type: 'ObjectExpression'
            properties: []
        for key, value of object
            if value isnt undefined
                node.properties.push
                    key:
                        type: 'Identifier' 
                        name: key
                    value: nodeToLiteral value
                    kind: 'init'
    else
        node =
            type: 'Literal'
            value: object
    return node

# wraps a node in a BlockStatement if it isn't already.
block = (node) ->
    if node.type isnt 'BlockStatement'
        node =
            type: 'BlockStatement'
            body: [node]
    return node

extractForLoopRightVariable = (node, context) ->
    return if context.reactive

    if node.type is 'ForOfStatement' or node.type is 'ForInStatement' and node.left.declarations.length > 1
        if node.left.declarations.length > 2
            throw context.error "too many declarations", node.left.declarations[2]
        right = node.right
        if right.type isnt "Identifier"
            ref = context.getNewInternalIdentifier()
            node.right = ref
            context.replace
                type: "BlockStatement"
                body: [
                    {type:"VariableDeclaration",declarations:[{type:"VariableDeclarator",id:ref,init:right}],kind:node.left.kind}
                    node
                ]

createForInLoopValueVariable = (node, context) ->
    return if context.reactive

    if node.type is 'ForInStatement' and node.left.declarations.length > 1
        valueDeclarator = node.left.declarations[1]
        context.addVariable
            id: valueDeclarator.id
            init:
                type: 'MemberExpression'
                computed: true
                object: node.right
                property: node.left.declarations[0].id

convertForInToForLength = (node, context) ->
    return if context.reactive

    if node.type is 'ForOfStatement'
        userIndex = node.left.declarations[1]?.id
        loopIndex = context.getNewInternalIdentifier "_i"

        addStatement node,
            type:"VariableDeclaration"
            declarations:[
                {
                    type:"VariableDeclarator"
                    id: node.left.declarations[0].id
                    init:
                        type: "MemberExpression"
                        object: node.right
                        property: loopIndex
                        computed: true
                }
            ]
            kind: node.left.kind

        if userIndex?
            addStatement node,
                type:"VariableDeclaration"
                declarations:[
                    {
                        type:"VariableDeclarator"
                        id: userIndex
                        init: loopIndex
                    }
                ]
                kind: node.left.kind

        context.replace
            type: 'ForStatement'
            init:
                type:"VariableDeclaration"
                declarations:[
                    { type:"VariableDeclarator",id:loopIndex,init:{ type:"Literal", value:0 } }
                ]
                kind: 'let'
            test:
                type: "BinaryExpression"
                operator: "<"
                left: loopIndex
                right:
                    type: "MemberExpression"
                    object: node.right
                    property: { type: "Identifier", name: "length" }
                    computed: false
            update:
                type: "UpdateExpression"
                operator: "++"
                argument: loopIndex
                prefix: false
            body: node.body

callFunctionBindForFatArrows = (node, context) ->
    if node.type is 'FunctionExpression' and node.bound
        delete node.bound
        context.replace
            type: "CallExpression"
            callee:
                type: "MemberExpression"
                object: node
                property:
                    type: "Identifier"
                    name: "bind"
            arguments: [ { type:"ThisExpression" } ]

nodejsModules = (node, context) ->
    # convert ImportExpression{name} into require(name)
    if node.type is 'ImportExpression'
        node.type = 'CallExpression'
        node.callee =
            type: 'Identifier'
            name: 'require'
        node.arguments = [node.name]
        delete node.name
    else if node.type is 'ExportStatement'
        if node.value.type is 'VariableDeclaration'
            # variable export
            context.exports = true
            # replace this node with the VariableDeclaration
            context.replace node.value
            # then make each init also assign to it's export variable.
            for declarator in node.value.declarations by -1
                if not declarator.init?
                    throw context.error "Export variables must have an init value", declarator
                declarator.init =
                    type: 'AssignmentExpression'
                    operator: '='
                    left:
                        type: 'MemberExpression'
                        object:
                            type: 'Identifier'
                            name: 'exports'
                        property: declarator.id
                    right: declarator.init
        else
            # default export
            if context.exports
                throw context.error "default export must be first"
            context.replace
                type: 'ExpressionStatement'
                expression:
                    type: 'AssignmentExpression'
                    operator: '='
                    left:
                        type: 'MemberExpression'
                        object:
                            type: 'Identifier'
                            name: 'module'
                        property:
                            type: 'Identifier'
                            name: 'exports'
                    right:
                        type: 'AssignmentExpression'
                        operator: '='
                        left:
                            type: 'Identifier'
                            name: 'exports'
                        right: node.value

# separateAllVariableDeclarations = (node, context) ->
#     if node.type is 'VariableDeclaration' and context.isParentBlock()
#         while node.declarations.length > 1
#             declaration = node.declarations.pop()
#             context.addStatement
#                 type: node.type
#                 declarations: [declaration]
#                 kind: node.kind

destructuringAssignments = (node, context) ->
    isPattern = (node) -> node.properties? or node.elements?

    # function parameters
    if isFunctionNode node
        for pattern, index in node.params when isPattern pattern
            tempId = context.getNewInternalIdentifier()
            node.params[index] = tempId
            statements = []
            forEachDestructuringAssignment pattern, tempId, (id, expression) ->
                statements.unshift {
                        type: 'VariableDeclaration'
                        declarations: [{
                            type: 'VariableDeclarator'
                            id: id
                            init: expression
                        }]
                        kind: 'let'
                    }
            for statement in statements
                context.addStatement statement

    # variable assignments
    if node.type is 'VariableDeclaration' and context.isParentBlock()
        for declarator in node.declarations when isPattern declarator.id
            pattern = declarator.id
            tempId = context.getNewInternalIdentifier()
            declarator.id = tempId
            count = 0
            forEachDestructuringAssignment pattern, tempId, (id, expression) ->
                context.addStatement {
                        type: 'VariableDeclaration'
                        declarations: [{
                            type: 'VariableDeclarator'
                            id: id
                            init: expression
                        }]
                        kind: 'let'
                    }, ++count

    # other assignments
    if node.type is 'ExpressionStatement' and node.expression.operator is '='
        expression = node.expression
        pattern = expression.left
        if isPattern pattern
            tempId = context.getNewInternalIdentifier()
            context.replace
                type: 'VariableDeclaration'
                declarations: [{
                    type: 'VariableDeclarator'
                    id: tempId
                    init: expression.right
                }]
                kind: 'const'

            count = 0
            forEachDestructuringAssignment pattern, tempId, (id, expression) ->
                context.addStatement {
                        type: 'ExpressionStatement'
                        expression:
                            type: 'AssignmentExpression'
                            operator: '='
                            left: id
                            right: expression
                    }, ++count

defaultOperatorsToConditionals = (node, context) ->
    if node.type is 'BinaryExpression' and (node.operator is '??' or node.operator is '?')
        context.replace
            type: 'ConditionalExpression'
            test:
                type: 'BinaryExpression'
                operator: '!='
                left: node.left
                right: if node.operator is '??' then undefinedExpression else nullExpression
            consequent: node.left
            alternate: node.right

defaultAssignmentsToDefaultOperators = (node, context) ->
    if node.type is 'AssignmentExpression' and (node.operator is '?=' or node.operator is '??=')
        # a ?= b --> a = a ? b
        node.right =
            type: 'BinaryExpression'
            operator: if node.operator is '?=' then '?' else '??'
            left: node.left
            right: node.right
        node.operator = '='

existentialExpression = (node, context) ->

    if node.type is 'UnaryExpression' and node.operator is '?'
        context.replace
            type: 'BinaryExpression'
            operator: '!='
            left: node.argument
            right: nullExpression

    # this could be more efficient by caching the left values
    # especially when the left side involves existential CallExpressions
    # should only apply within an imperative context
    if node.type is 'MemberExpression' or node.type is 'CallExpression'
        # search descendant objects for deepest existential child
        getExistentialDescendantObject = (check) ->
            result = null
            if check.type is 'MemberExpression' or check.type is 'CallExpression'
                result = getExistentialDescendantObject check.object ? check.callee
                if check.existential
                    result ?= check
            return result
        # create temp ref variable
        # a?.b --> a != null ? a.b : undefined
        existentialChild  = getExistentialDescendantObject node
        if existentialChild?
            existentialChildObject = existentialChild.object ? existentialChild.callee
            delete existentialChild.existential
            context.replace
                type: 'ConditionalExpression'
                test:
                    type: 'BinaryExpression'
                    operator: '!='
                    left: existentialChildObject
                    right: nullExpression
                consequent: node
                alternate: undefinedExpression

ensureIonVariable = (context, required = true) ->
    context.ancestorNodes[0].requiresIon = required

addUseStrictAndRequireIon =
    enter: (node, context) ->
        # see if we are already importing ion at the Program scope
        if node.type is 'VariableDeclaration' and context.parentNode()?.type is 'Program'
            for d in node.declarations when d.id.name is 'ion'
                # we don't need to import ion because the user already did
                ensureIonVariable context, false
                break
    exit: (node, context) ->
        if node.type is 'Program'
            if node.requiresIon
                delete node.requiresIon
                context.addVariable
                    offset: Number.MIN_VALUE
                    kind: 'const'
                    id: ionExpression
                    init:
                        type: 'ImportExpression'
                        name:
                            type: 'Literal'
                            value: 'ion'
            node.body.unshift
                type: 'ExpressionStatement'
                expression:
                    type: 'Literal'
                    value: 'use strict'

extractForLoopsInnerAndTest = (node, context) ->
    if node.type is 'ForInStatement' or node.type is 'ForOfStatement'
        if node.inner?
            node.inner.body = node.body
            node.body = node.inner
            delete node.inner
        if node.test?
            node.body = block
                type: 'IfStatement'
                test: node.test
                consequent: block node.body
            delete node.test

arrayComprehensionsToES5 = (node, context) ->
    if node.type is 'ArrayExpression' and node.value? and node.comprehension?
        if context.reactive
            # convert it to a typed object expression
            forStatement = node.comprehension
            forStatement.body =
                type: 'ExpressionStatement'
                expression: node.value
            context.replace
                type: 'ObjectExpression'
                objectType:
                    type: 'ArrayExpression'
                    elements: []
                properties: [forStatement]
        else
            # add a statement
            tempId = context.addVariable
                offset: 0
                init:
                    type: 'ArrayExpression'
                    elements: []
            forStatement = node.comprehension
            forStatement.body =
                type: 'ExpressionStatement'
                expression:
                    type: 'CallExpression'
                    callee:
                        type: 'MemberExpression'
                        object: tempId
                        property:
                            type: 'Identifier'
                            name: 'push'
                    arguments: [node.value]
            context.addStatement 0, forStatement
            context.replace tempId

functionParameterDefaultValuesToES5 = (node, context) ->
    return if context.reactive

    if isFunctionNode(node) and node.params? and node.defaults?
        for param, index in node.params by -1
            defaultValue = node.defaults?[index]
            if defaultValue?
                context.addStatement
                    type: 'IfStatement'
                    test:
                        type: 'BinaryExpression'
                        operator: '=='
                        left: param
                        right: nullExpression
                    consequent:
                        type: 'ExpressionStatement'
                        expression:
                            type: 'AssignmentExpression'
                            operator: '='
                            left: param
                            right: defaultValue
                node.defaults[index] = undefined

typedObjectExpressions = (node, context) ->
    # only for imperative code
    return if context.reactive

    if node.type is 'ObjectExpression' and node.simple isnt true

        isArray = node.objectType?.type is "ArrayExpression"
        isSimple = true
        if node.properties?
            for property in node.properties
                if isArray
                    if property.type isnt 'ExpressionStatement'
                        isSimple = false
                        break
                else
                    if property.type isnt 'Property' or property.computed
                        isSimple = false
                        break

        # empty object expression without properties {}
        if isSimple
            if isArray
                elements = []
                if node.objectType?
                    for element in node.objectType.elements
                        elements.push element
                for expressionStatement in node.properties
                    elements.push expressionStatement.expression
                context.replace
                    type: "ArrayExpression"
                    elements: elements
                return
            if (not node.objectType? or (node.objectType.type is 'ObjectExpression' and node.objectType.properties.length is 0))
                # check that our properties ONLY contain normal Property objects with no computed values
                delete node.objectType
                # set simple to true, but make it non-enumerable so we don't write it out
                Object.defineProperty node, 'simple', {value:true}
                return

        if not node.objectType?
            initialValue =
                type: 'ObjectExpression'
                properties: []
        else if node.objectType.type is 'ArrayExpression' or node.objectType.type is 'NewExpression' or node.objectType.type is 'ObjectExpression'
            initialValue =
                node.objectType
        else
            initialValue =
                type: 'NewExpression'
                callee: node.objectType
                arguments: []

        parentNode = context.parentNode()
        grandNode = context.ancestorNodes[context.ancestorNodes.length-2]
        addPosition = 0
        getExistingObjectIdIfTempVarNotNeeded = (node, parentNode, grandNode) ->
            # don't need a temp variable because nothing can trigger on variable declaration
            if parentNode.type is 'VariableDeclarator'
                return parentNode.id
            # don't need a temp variable because nothing can trigger on variable assignment
            if parentNode.type is 'AssignmentExpression' and parentNode.left.type is 'Identifier' and grandNode?.type is 'ExpressionStatement'
                return parentNode.left
            # for everything else we must use a temp variable and assign all sub properties
            # before using the final value in an expression, because it may trigger a setter
            # or be a parameter in a function call or constructor
            return null

        objectId = getExistingObjectIdIfTempVarNotNeeded node, parentNode, grandNode
        if objectId?
            # replace this with the initial value
            context.replace initialValue
            addPosition = 1
        else
            # create a temp variable
            objectId = context.addVariable
                offset: 0
                init: initialValue
            # replace this with a reference to the variable
            context.replace objectId

        statements = []

        # traverse all properties and expression statements
        # add a new property that indicates their output scope
        traverse node.properties, (subnode, subcontext) ->
            if subnode.type is 'ObjectExpression' or subnode.type is 'ArrayExpression'
                return subcontext.skip()
            if subnode.type is 'Property' #or subnode.type is 'ExpressionStatement'
                # we convert the node to a Property: ObjectExpression node
                # it will be handled correctly by the later propertyStatements rule
                subnode = subcontext.replace
                    type: 'Property'
                    key: objectId
                    value:
                        type: 'ObjectExpression'
                        properties: [subnode]
                        create: false
                subcontext.skip()
            else if subnode.type is 'ExpressionStatement'
                if not isArray
                    ensureIonVariable(context)
                subnode = subcontext.replace
                    type: 'ExpressionStatement'
                    expression:
                        type: 'CallExpression'
                        callee:
                            type: 'MemberExpression'
                            object: if isArray then objectId else ionExpression
                            property:
                                type: 'Identifier'
                                name: if isArray then 'push' else 'add'
                        arguments: if isArray then [subnode.expression] else [objectId, subnode.expression]
                subcontext.skip()

            if not subcontext.parentNode()?
                # add this statement to the current context
                statements.push subnode
        if statements.length is 1
            context.addStatement statements[0], addPosition
        else
            context.addStatement {type:'BlockStatement',body:statements}, addPosition

propertyStatements = (node, context) ->
    return if context.reactive

    parent = context.parentNode()
    if node.type is 'Property' and not (parent.type is 'ObjectExpression' or parent.type is 'ObjectPattern')
        createAssignments = (path, value) ->
            if value.type is 'ObjectExpression' and not value.objectType?
                for property in value.properties by -1
                    newPath =
                        type: 'MemberExpression'
                        object: path
                        property: property.key
                        computed: property.computed || property.key.type isnt 'Identifier'
                    createAssignments newPath, property.value
                # assign an empty object if required
                if value.create isnt false
                    context.addStatement {
                        type: 'IfStatement'
                        test:
                            type: 'BinaryExpression'
                            operator: '=='
                            left: path
                            right: nullExpression
                        consequent:
                            type: 'ExpressionStatement'
                            expression:
                                type: 'AssignmentExpression'
                                operator: '='
                                left: path
                                right:
                                    type: 'ObjectExpression'
                                    properties: []
                    }, 0
            else
                context.addStatement {
                    type: 'ExpressionStatement'
                    expression:
                        type: 'AssignmentExpression'
                        operator: '='
                        left: path
                        right: value
                }, 0
        createAssignments node.key, node.value
        context.remove node

classExpressions = (node, context) ->

    if node.type is 'ClassExpression'
        ensureIonVariable context

        properties = node.properties
        hasIdentifierName = node.name? and not node.computed
        if node.name?
            name = if hasIdentifierName then {type:'Literal',value:node.name.name} else node.name
            # add id to the properties
            properties = [{type:'Property',key:{type:'Identifier',name:'id'},value:name}].concat properties
        # set the class name on the constructor function
        if hasIdentifierName
            for property in properties when property.key.name is 'constructor'
                property.value.id ?= node.name
        classExpression =
            type: 'CallExpression'
            callee:
                type: 'MemberExpression'
                object: ionExpression
                property:
                    type: 'Identifier'
                    name: 'defineClass'
            arguments: [{type: 'ObjectExpression',properties: properties}].concat node.extends

        if hasIdentifierName
            context.addVariable
                id: node.name
                kind: 'const'
                init: classExpression
                offset: 0
            context.replace node.name
        else
            context.replace classExpression

checkVariableDeclarations =
    enter: (node, context) ->
        # check assigning to a constant
        if node.type is 'AssignmentExpression'
            if node.left.type is 'Identifier'
                variable = context.getVariableInfo(node.left.name)
                if not variable?
                    throw context.error "cannot assign to undeclared variable #{node.left.name}"
                if variable.kind is 'const'
                    throw context.error "cannot assign to a const", node.left
            if context.reactive
                throw context.error "cannot assign within templates", node
        # track variable usage on a scope
        if node.type is 'Identifier'
            key = context.key()
            parent = context.parentNode()
            if not (parent.type is 'MemberExpression' and key is 'property' or parent.type is 'Property' and key is 'key')
                # then this is a variable usage, so we will track it.
                (context.scope().usage ?= {})[node.name] = node
    variable: (variable, context) ->
        scope = context.scope()
        # check that we arent redeclaring a variable
        existing = context.getVariableInfo(variable.name)
        if existing?
            # check to see if shadowing is allowed.
            # walk the scope stack backwards
            shadow = false
            for checkScope in context.scopeStack by -1
                # we only check back until we hit the scope
                # where the existing variable was declared
                if checkScope is existing?.scope
                    break
                # if we pass a scope that allows shadowing then we are ok
                if nodes[checkScope.node.type]?.shadow
                    shadow = true
                    break
            if not shadow
                throw context.error "Cannot redeclare variable #{variable.name}", variable.node
        # make sure we havent used this variable before declaration
        for checkScope in context.scopeStack by -1
            used = checkScope.usage?[variable.name]
            if used?
                throw context.error "Cannot use variable '#{variable.name}' before declaration", used
            # we only check back to a shadow, max
            if nodes[checkScope.node.type]?.shadow
                break

isAncestorObjectExpression = (context) ->
    for ancestor in context.ancestorNodes by -1
        if ancestor.type is 'ObjectExpression'
            return true
        if isFunctionNode(ancestor)
            return false
    return false

namedFunctions = (node, context) ->
    return if context.reactive

    # first, named functions expressions to function declarations
    if node.type is 'ExpressionStatement' and node.expression.type is 'FunctionExpression' and node.expression.id?
        func = node.expression
        func.type = 'FunctionDeclaration'
        context.replace func
    # these names are used later by the classExpression rule
    # add an internal name to functions declared as variables
    if node.type is 'VariableDeclarator' and node.init?.type is 'FunctionExpression'
        node.init.name ?= node.id
    # add an internal name to functions declared as properties
    if node.type is 'Property' and node.value.type is 'FunctionExpression' and node.key.type is 'Identifier'
        if node.key.name isnt 'constructor'
            node.value.name ?= node.key

assertStatements = (node, context) ->
    if node.type is 'AssertStatement'
        context.replace
            type: 'IfStatement'
            test:
                type: 'UnaryExpression'
                prefix: true
                operator: '!'
                argument: node.expression
            consequent:
                type: 'ThrowStatement'
                argument:
                    type: 'NewExpression'
                    callee:
                        type: 'Identifier'
                        name: 'Error'
                    arguments: [
                        type: 'Literal'
                        value: "Assertion Failed: (#{node.text})"
                    ]

isSuperExpression = (node, context) ->
    parentNode = context.parentNode()
    if node.type is 'Identifier' and node.name is 'super' and parentNode.type isnt 'CallExpression' and parentNode.type isnt 'MemberExpression'
        return true
    if node.type is 'CallExpression' and node.callee.type is 'Identifier' and node.callee.name is 'super'
        return true
    return false

superExpressions = (node, context) ->
    if isSuperExpression node, context
        classNode = context.getAncestor (node) -> node.type is 'ClassExpression'
        functionNode = context.getAncestor isFunctionNode
        functionProperty = context.ancestorNodes[context.ancestorNodes.indexOf(functionNode) - 1]
        isConstructor = functionProperty?.key?.name is 'constructor'

        if not classNode? or not (functionNode?.name? or isConstructor)
            throw context.error "super can only be used within named class functions", node

        args = [{type:'ThisExpression'}]
        if node.type is 'Identifier'
            args.push {type:'Identifier',name:'arguments'}
            applyOrCall = 'apply'
        else
            args = args.concat node.arguments
            applyOrCall = 'call'
        superFunction = getPathExpression "#{classNode.name.name}.super"

        if not isConstructor
            superFunction =
                type: 'MemberExpression'
                object:
                    type: 'MemberExpression'
                    object: superFunction
                    property:
                        type: 'Identifier'
                        name: 'prototype'
                property: functionNode.name ? 'constructor'

        context.replace
            type: 'CallExpression'
            callee:
                type: 'MemberExpression'
                object:
                    superFunction
                property:
                    type: 'Identifier'
                    name: applyOrCall
            arguments: args

spreadExpressions = (node, context) ->
    # function rest parameters
    if isFunctionNode node
        spread = null
        spreadIndex = null
        for param, index in node.params
            if param.type is 'SpreadExpression'
                spread = param
                spreadIndex = index
                break
        if spread?
            # replace the spread parameter with a placeholder named parameter
            node.params[spreadIndex] =
                type: 'Identifier'
                name: "___" + spread.expression.name
            # add a variable that extracts the spread
            args = [
                {type:'Identifier', name:'arguments'}
                {type:'Literal', value:spreadIndex}
            ]
            finalParameters = node.params.length - 1 - spreadIndex
            if finalParameters > 0
                # add a third arg to the slice that removes the final parameters from the end
                getOffsetFromArgumentsLength = (offset) ->
                    return {
                        type: 'BinaryExpression'
                        operator: '-'
                        left: getPathExpression 'arguments.length'
                        right: {type:'Literal', value: offset }
                    }
                args.push getOffsetFromArgumentsLength finalParameters
                # extract the correct values for the final variables.
                index = node.params.length - 1
                while index > spreadIndex
                    param = node.params[index--]
                    context.addStatement
                        type: 'ExpressionStatement'
                        expression:
                            type: 'AssignmentExpression'
                            operator: '='
                            left: param
                            right:
                                type: 'MemberExpression'
                                computed: true
                                object: getPathExpression 'arguments'
                                property: getOffsetFromArgumentsLength node.params.length - 1 - index
            context.addVariable
                id: spread.expression
                init:
                    type: 'CallExpression'
                    callee: getPathExpression 'Array.prototype.slice.call'
                    arguments: args

createTemplateFunctionClone = (node, context) ->
    if isFunctionNode(node) and node.template is true
        if node.bound
            throw context.error "Templates cannot use the fat arrow (=>) binding syntax", node
        delete node.template
        template = ion.clone node, true
        template.type = 'Template'
        delete template.id
        delete template.defaults
        delete template.bound
        Object.defineProperties template,
            type: {value:'Template'}
        node.template = template

validateTemplateNodes = (node, context) ->
    if context.reactive
        if nodes[node.type]?.allowedInReactive is false
            throw context.error node.type + " not allowed in templates", node

    if context.parentReactive()
        # also, convert FunctionDeclaration to variable declarations with function expression
        if node.type is 'FunctionDeclaration'
            node.type = 'FunctionExpression'
            context.replace
                type: 'VariableDeclaration'
                kind: 'const'
                declarations: [
                    type: 'VariableDeclarator'
                    id: node.id
                    init: node
                ]

    # if node.type is 'VariableDeclaration' and node.kind is 'let'
    #     throw context.error "only const variables are allowed in templates", node

removeLocationInfo = (node) ->
    traverse node, (node) ->
        if node.loc?
            delete node.loc
        return node

# gets all identifiers, except member access properties
getExternalIdentifiers = (node, callback) ->
    traverse node, (node, context) ->
        if node.type is 'Identifier'
            # ignore member expression right hand identifiers
            if context.parentNode()?.type is 'MemberExpression' and context.key() is 'property'
                return
            # ignore object property keys
            if context.parentNode()?.type is 'Property' and context.key() is 'key'
                return
            # ignore internally defined variables
            if context.getVariableInfo(node.name)?
                return
            callback(node)
    return

wrapTemplateInnerFunctions = (node, context) ->
    if context.parentReactive()
        if node.type is 'FunctionExpression' and not node.toLiteral?
            console.log '>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>', node.name?.name
            for key, value of context.scope().variables
                console.log '::::::::::::::::::::::::::::::::', key
            # see if we need to replace any properties in this function or not.
            variables = {}
            getExternalIdentifiers node, (id) ->
                console.log('ID: ' + id.name, context.getVariableInfo(id.name))
                if id.name isnt node.id?.name and context.scope()?.variables[id.name]?
                    variables[id.name] = id
            requiresWrapper = Object.keys(variables).length > 0
            if requiresWrapper
                # now convert the node to a new wrapped node
                # add a statement extracting each needed variable from the reactive context
                contextId = context.getNewInternalIdentifier('_context')
                node.body.body.unshift
                    type: 'VariableDeclaration'
                    kind: 'const'
                    declarations: (for name, id of variables
                        type: 'VariableDeclarator'
                        id: id
                        init:
                            type: 'CallExpression'
                            callee: getPathExpression "#{contextId.name}.get"
                            arguments: [
                                type: 'Literal'
                                value: id.name
                            ]
                    )
                node =
                    type: 'FunctionExpression'
                    params: [contextId]
                    body:
                        type: 'BlockStatement'
                        body: [
                            type: 'ReturnStatement'
                            argument: node
                        ]

            node.toLiteral = -> @
            context.replace
                type: 'Function'
                context: requiresWrapper
                value: node

createTemplateRuntime = (node, context) ->
    if isFunctionNode(node) and node.template?
        templateId = node.id ?= context.getNewInternalIdentifier('_template')
        template = removeLocationInfo node.template
        ensureIonVariable context

        # create an arguments object that contains all the parameter values.
        args =
            type: 'ObjectExpression'
            properties: []
        variables = {}
        # if nodejs, add built in ids
        for name in ['require', 'module', 'exports']
            variables[name] = { type: 'Identifier', name: name }
        for id in template.params
            variables[id.name] = id
        # also add any variables in scope
        for key, value of context.scope().variables
            id = value.id
            variables[id.name] = id
        for key, id of variables
            args.properties.push
                key: id
                value: id
                kind: 'init'

        # now delete template params because we don't need them at runtime
        delete template.params
        # move the template.body.body just to template.body
        template.body = template.body.body

        context.addStatement
            type: 'IfStatement'
            # test for if this is a new object thingy.
            test:
                type: 'BinaryExpression'
                operator: '&&'
                left:
                    type: 'BinaryExpression'
                    operator: '!='
                    left: thisExpression
                    right: nullExpression
                right:
                    type: 'BinaryExpression'
                    operator: '==='
                    left: getPathExpression 'this.constructor'
                    right: templateId
            consequent: block
                type: 'ReturnStatement'
                argument:
                    type: 'CallExpression'
                    callee: getPathExpression 'ion.createRuntime'
                    arguments: [
                        nodeToLiteral template
                        args
                    ]
        delete node.template

javascriptExpressions = (node, context) ->
    if node.type is 'JavascriptExpression'
        esprima = require 'esprima'
        try
            program = esprima.parse node.text
            expression = program.body[0].expression
            context.replace expression
        catch e
            errorNode = ion.clone node, true
            errorNode.loc?.start.line += e.lineNumber - 1
            errorNode.loc?.start.column += e.column - 1 + "`".length
            message = e.message.substring(e.message.indexOf(':') + 1).trim()
            throw context.error message, errorNode

exports.postprocess = (program, options) ->
    steps = [
        [namedFunctions, superExpressions]
        [destructuringAssignments]
        [createTemplateFunctionClone, checkVariableDeclarations]
        [javascriptExpressions, arrayComprehensionsToES5, extractForLoopsInnerAndTest, extractForLoopRightVariable, callFunctionBindForFatArrows]
        [validateTemplateNodes, classExpressions]
        [createForInLoopValueVariable, convertForInToForLength, typedObjectExpressions, propertyStatements, defaultAssignmentsToDefaultOperators, defaultOperatorsToConditionals, wrapTemplateInnerFunctions, nodejsModules]
        [destructuringAssignments, existentialExpression, createTemplateRuntime, functionParameterDefaultValuesToES5]
        [addUseStrictAndRequireIon]
        [nodejsModules, spreadExpressions, assertStatements]
    ]
    previousContext = null
    for traversal in steps
        enter = (node, context) ->
            previousContext = context
            context.options ?= options
            for step in traversal when node?
                handler = step.enter ? (if typeof step is 'function' then step else null)
                if handler?
                    handler node, context
                    node = context.current()
        exit = (node, context) ->
            for step in traversal by -1 when node?
                handler = step.exit ? null
                if handler?
                    handler node, context
                    node = context.current()
        variable = (node, context, kind, name) ->
            for step in traversal when node?
                handler = step.variable ? null
                if handler?
                    handler node, context, kind, name
                    node = context.current()
        traverse program, enter, exit, variable, previousContext
    program
