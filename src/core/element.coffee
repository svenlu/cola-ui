#IMPORT_BEGIN
if exports?
	cola = require("./util")
	module?.exports = cola
else
	cola = @cola
#IMPORT_END

tagSplitter = " "

doMergeDefinitions = (definitions, mergeDefinitions, overwrite) ->
	return if definitions == mergeDefinitions
	for name, mergeDefinition of mergeDefinitions
		if definitions.hasOwnProperty(name)
			definition = definitions[name]
			if definition
				for prop of mergeDefinition
					if overwrite or !definition.hasOwnProperty(prop) then definition[prop] = mergeDefinition[prop]
			else
				definitions[name] = mergeDefinition
		else
			definitions[name] = mergeDefinition
	return

preprocessClass = (classType) ->
	superType = classType.__super__?.constructor
	if superType
		if classType.__super__ then preprocessClass(superType)

		# merge ATTRIBUTES
		# TODO: 此处可以考虑预先计算出有无含默认值设置的属性，以便在对象创建时提高性能
		attributes = classType.ATTRIBUTES
		if !attributes._inited
			attributes._inited = true
			doMergeDefinitions(attributes, superType.ATTRIBUTES, false)

		# merge EVENTS
		events = classType.EVENTS
		if !events._inited
			events._inited = true
			doMergeDefinitions(events, superType.EVENTS, false)
	return

class cola.Element
	@mixin: (classType, mixin) ->
		for name, member of mixin
			if name == "ATTRIBUTES"
				mixinAttributes = member
				if mixinAttributes
					attributes = classType.ATTRIBUTES ?= {}
					doMergeDefinitions(attributes, mixinAttributes, true)
			else if name == "EVENTS"
				mixInEvents = member
				if mixInEvents
					events = classType.EVENTS ?= {}
					doMergeDefinitions(events, mixInEvents, true)
			else if name == "constructor"
				if !classType._constructors
					classType._constructors = [member]
				else
					classType._constructors.push(member)
			else if name == "destroy"
				if !classType._destructors
					classType._destructors = [member]
				else
					classType._destructors.push(member)
			else
				classType.prototype[name] = member
		return

	@ATTRIBUTES:
		tag:
			getter: ->
				return if @_tag then @_tag.join(tagSplitter) else null
			setter: (tag) ->
				cola.tagManager.unreg(t, @) for t in @_tag if @_tag
				if tag
					@_tag = ts = tag.split(tagSplitter)
					cola.tagManager.reg(t, @) for t in ts
				else
					@_tag = null
				return

		userData: null

	@EVENTS:
		attributeChange: null
		destroy: null

	constructor: (config) ->
		@_constructing = true
		classType = @constructor
		if !classType.ATTRIBUTES._inited or !classType.EVENTS._inited
			preprocessClass(classType)

		@_scope = config?.scope or cola.currentScope

		attrConfigs = classType.ATTRIBUTES
		for attr, attrConfig of attrConfigs
			if attrConfig?.defaultValue != undefined
				if attrConfig.setter
					attrConfig.setter.call(@, attrConfig.defaultValue, attr)
				else
					@["_" + attr] = attrConfig.defaultValue

		if classType._constructors
			for constructor in classType._constructors
				constructor.call(@)

		if config then @set(config, true)
		delete @_constructing

	destroy: ()->
		classType = @constructor
		if classType._destructors
			for destructor in classType._destructors
				destructor.call(@)

		if @_elementAttrBindings
			for p, elementAttrBinding of @_elementAttrBindings
				elementAttrBinding.destroy()

		@fire("destroy", @)
		@_set("tag", null) if @_tag
		return

	get: (attr, ignoreError) ->
		if attr.indexOf(".") > -1
			paths = attr.split(".")
			obj = @
			for path in paths
				if obj instanceof cola.Element
					obj = obj._get(path, ignoreError)
				else if typeof obj.get == "function"
					obj = obj.get(path)
				else
					obj = obj[path]
				if !obj? then break
			return obj
		else
			return @_get(attr, ignoreError)

	_get: (attr, ignoreError) ->
		if !@constructor.ATTRIBUTES.hasOwnProperty(attr)
			if ignoreError then return
			throw new cola.Exception("Unrecognized Attribute \"#{attr}\".")

		attrConfig = @constructor.ATTRIBUTES[attr]
		if attrConfig?.getter
			return attrConfig.getter.call(@, attr)
		else
			return @["_" + attr]

	set: (attr, value, ignoreError) ->
		if typeof attr == "string"
			# set(string, any)
			if attr.indexOf(".") > -1
				paths = attr.split(".")
				obj = @
				for path, i in paths
					if obj instanceof cola.Element
						obj = obj._get(path, ignoreError)
					else
						obj = obj[path]
					if !obj? then break
					if i >= (paths.length - 2) then break

				if !obj? and !ignoreError
					throw new cola.Exception("Cannot set attribute \"#{path[0...i].join(".")}\" of undefined.")

				if obj instanceof cola.Element
					obj._set(paths[paths.length - 1], value, ignoreError)
				else if typeof obj.set == "function"
					obj.set(paths[paths.length - 1], value)
				else
					obj[paths[paths.length - 1]] = value
			else
				@_set(attr, value, ignoreError)
		else
			# set(object, ignoreError)
			config = attr
			ignoreError = value
			for attr of config
				@set(attr, config[attr], ignoreError)
		return @

	_set: (attr, value, ignoreError) ->
		if typeof value == "string" and @_scope
			if value.charCodeAt(0) == 123 # `{`
				parts = cola._compileText(value)
				if parts?.length > 0
					value = parts[0]

		if @constructor.ATTRIBUTES.hasOwnProperty(attr)
			attrConfig = @constructor.ATTRIBUTES[attr]
			if attrConfig
				if attrConfig.readOnly
					if ignoreError then return
					throw new cola.Exception("Attribute \"#{attr}\" is readonly.")

				if !@_constructing and attrConfig.readOnlyAfterCreate
					if ignoreError then return
					throw new cola.Exception("Attribute \"#{attr}\" cannot be changed after create.")
		else if value
			eventName = attr
			i = eventName.indexOf(":")
			if i > 0 then eventName = eventName.substring(0, i)
			if @constructor.EVENTS.hasOwnProperty(eventName)
				if value instanceof cola.Expression
					expression = value
					scope = @_scope
					@on(attr, (self, arg) ->
						expression.evaluate(scope, "never", {
							vars:
								self: self
								arg: arg
						})
						return
					, ignoreError)
					return
				else if typeof value == "function"
					@on(attr, value)
					return
				else if typeof value == "string"
					action = @_scope?.action(value)
					if action
						@on(attr, action)
						return

			if ignoreError then return
			throw new cola.Exception("Unrecognized Attribute \"#{attr}\".")

		@_doSet(attr, attrConfig, value)

		if @_eventRegistry
			if @getListeners("attributeChange")
				@fire("attributeChange", @, {attribute: attr})
		return

	_doSet: (attr, attrConfig, value) ->
		if !@_duringBindingRefresh and @_elementAttrBindings
			elementAttrBinding = @_elementAttrBindings[attr]
			if elementAttrBinding
				elementAttrBinding.destroy()
				delete @_elementAttrBindings[attr]

		if value instanceof cola.Expression and cola.currentScope
			expression = value
			scope = cola.currentScope
			if expression.isStatic
				value = expression.evaluate(scope, "never")
			else
				elementAttrBinding = new cola.ElementAttrBinding(@, attr, expression, scope)

				@_elementAttrBindings ?= {}
				elementAttrBindings = @_elementAttrBindings
				if elementAttrBindings
					elementAttrBindings[attr] = elementAttrBinding
				value = elementAttrBinding.evaluate()

		if attrConfig
			if attrConfig.type is "boolean"
				if value? and typeof value isnt "boolean"
					value = value is "true"
			else if attrConfig.type is "number"
				if value? and typeof value isnt "number"
					value = parseFloat(value) or 0

			if attrConfig.enum and attrConfig.enum.indexOf(value) < 0
				throw new cola.Exception("The value \"#{value}\" of attribute \"#{attr}\" is out of range.")

			if attrConfig.setter
				attrConfig.setter.call(@, value, attr )
				return

		@["_" + attr] = value
		return

	_on: (eventName, listener, alias, once) ->
		eventConfig = @constructor.EVENTS[eventName]

		if @_eventRegistry
			listenerRegistry = @_eventRegistry[eventName]
		else
			@_eventRegistry = {}

		if !listenerRegistry
			@_eventRegistry[eventName] = listenerRegistry = {}

		if once
			listenerRegistry.onceListeners ?= []
			listenerRegistry.onceListeners.push(listener)

		listeners = listenerRegistry.listeners
		aliasMap = listenerRegistry.aliasMap
		if listeners
			if eventConfig?.singleListener and listeners.length
				throw new cola.Exception("Multi listeners is not allowed for event \"#{eventName}\".")

			if alias and aliasMap?[alias] > -1 then cola.off(eventName + ":" + alias)
			listeners.push(listener)
			i = listeners.length - 1
		else
			listenerRegistry.listeners = listeners = [listener]
			i = 0

		if alias
			if !aliasMap
				listenerRegistry.aliasMap = aliasMap = {}
			aliasMap[alias] = i
		return

	on: (eventName, listener, once) ->
		i = eventName.indexOf(":")
		if i > 0
			alias = eventName.substring(i + 1)
			eventName = eventName.substring(0, i)

		if !@constructor.EVENTS.hasOwnProperty(eventName)
			throw new cola.Exception("Unrecognized event \"#{eventName}\".")

		if typeof listener != "function"
			throw new cola.Exception("Invalid event listener.")

		@_on(eventName, listener, alias, once)
		return @

	one: (eventName, listener) ->
		@on(eventName, listener, true)

	_off: (eventName, listener, alias) ->
		listenerRegistry = @_eventRegistry[eventName]
		return @ unless listenerRegistry

		listeners = listenerRegistry.listeners
		return @ unless listeners and listeners.length

		i = -1
		if alias or listener
			if alias
				aliasMap = listenerRegistry.aliasMap
				i = aliasMap?[alias]

				if i > -1
					delete aliasMap?[alias]
					listener = listeners[i]
					listeners.splice(i, 1)
			else if listener
				i = listeners.indexOf(listener)
				if i > -1
					listeners.splice(i, 1)

					aliasMap = listenerRegistry.aliasMap
					if aliasMap
						for alias of aliasMap
							if aliasMap[alias] == listener
								delete aliasMap[alias]
								break

			if listenerRegistry.onceListeners and listener
				onceListeners = listenerRegistry.onceListeners
				i = onceListeners.indexOf(listener)
				if i > -1
					onceListeners.splice(i, 1)
					if not onceListeners.length
						delete listenerRegistry.onceListeners
		else
			delete listenerRegistry.listeners
			delete listenerRegistry.aliasMap
		return

	off: (eventName, listener) ->
		return @ unless @_eventRegistry

		i = eventName.indexOf(":")
		if i > 0
			alias = eventName.substring(i + 1)
			eventName = eventName.substring(0, i)

		@_off(eventName, listener, alias)
		return @

	getListeners: (eventName) ->
		return @_eventRegistry?[eventName]?.listeners

	fire: (eventName, self, arg) ->
		return unless @_eventRegistry

		result = undefined
		listenerRegistry = @_eventRegistry[eventName]
		if listenerRegistry
			listeners = listenerRegistry.listeners
			if listeners
				if arg
					arg.model = @._scope
				else
					arg = {model: @._scope}

				for listener in listeners
					if typeof listener == "function"
						argsMode = listener._argsMode
						if not listener._argsMode
							argsMode = cola.util.parseListener(listener)
						if argsMode == 1
							retValue = listener.call(self, self, arg)
						else
							retValue = listener.call(self, arg, self)
					else if typeof listener == "string"
						retValue = do (self, arg) => eval(listener)

					if retValue != undefined then result = retValue
					if retValue == false then break

				if listenerRegistry.onceListeners
					onceListeners = listenerRegistry.onceListeners.slice()
					delete listenerRegistry.onceListeners
					@off(eventName, listener) for listener in onceListeners

		return result

class cola.Definition extends cola.Element
	@ATTRIBUTES:
		name:
			readOnlyAfterCreate: true

	constructor: (config) ->
		if config?.name
			@_name = config.name
			delete config.name
			scope = config?.scope or cola.currentScope
			if scope
				scope.data.regDefinition(@)
		super(config)

###
    Element Group
###
cola.Element.createGroup = (elements, model) ->
	if model
		elements = []
		for ele in elements
			if ele._scope && !ele._model
				scope = ele._scope
				while scope
					if scope instanceof cola.Scope
						ele._model = scope
						break
					scope = scope.parent
			if ele._model == model then elements.push(ele)
	else
		elements = if elements then elements.slice(0) else []

	elements.set = (attr, value) ->
		element.set(attr, value) for element in elements
		return @
	elements.on = (eventName, listener, once) ->
		element.on(eventName, listener, once) for element in elements
		return @
	elements.off = (eventName) ->
		element.off(eventName) for element in elements
		return @
	return elements

###
    Tag Manager
###

cola.tagManager =
	registry: {}

	reg: (tag, element) ->
		elements = @registry[tag]
		if elements
			elements.push(element)
		else
			@registry[tag] = [element]
		return

	unreg: (tag, element) ->
		if element
			elements = @registry[tag]
			if elements
				i = elements.indexOf(element)
				if i > -1
					if i == 0 and elements.length == 1
						delete @registry[tag]
					else
						elements.splice(i, 1)
		else
			delete @registry[tag]
		return

	find: (tag) ->
		return @registry[tag]

cola.tag = (tag) ->
	elements = cola.tagManager.find(tag)
	return cola.Element.createGroup(elements)

###
    Type Registry
###

typeRegistry = {}

cola.registerType = (namespace, typeName, constructor) ->
	holder = typeRegistry[namespace] or typeRegistry[namespace] = {}
	holder[typeName] = constructor
	return

cola.registerTypeResolver = (namespace, typeResolver) ->
	holder = typeRegistry[namespace] or typeRegistry[namespace] = {}
	holder._resolvers ?= []
	holder._resolvers.push(typeResolver)
	return

cola.resolveType = (namespace, config, baseType) ->
	constructor = null
	holder = typeRegistry[namespace]
	if holder
		constructor = holder[config?.$type or "_default"]
		if !constructor and holder._resolvers
			for resolver in holder._resolvers
				constructor = resolver(config)
				if constructor
					if baseType and !cola.util.isCompatibleType(baseType, constructor)
						throw new cola.Exception("Incompatiable class type.")
					break
		return constructor
	return

cola.create = (namespace, config, baseType) ->
	if typeof config is "string"
		config = {
			$type: config
		}
	constr = cola.resolveType(namespace, config, baseType)
	return new constr(config)