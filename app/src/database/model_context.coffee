
ledger.database = {} unless ledger.database?
ledger.database.contexts = {} unless ledger.database.contexts?

collectionNameForRelationship = (object, relationship) ->
  switch relationship.type
    when 'many_one' then relationship.Class
    when 'many_many' then _.sortBy([relationship.Class, object.constructor.name], ((s) -> s)).join('_')
    when 'one_many' then relationship.Class
    when 'one_one' then relationship.Class

class Collection

  constructor: (collection, context) ->
    @_collection = collection
    @_context = context

  insert: (model) ->
    model._object ?= {}
    model._object['objType'] = model.getCollectionName()
    model._object = @_collection.insert(model._object)
    @_context.notifyDatabaseChange()

  remove: (model) ->
    model._object = @_collection.remove(model._object)
    @_context.notifyDatabaseChange()

  update: (model) ->
    @_collection.update(model._object)
    @_context.notifyDatabaseChange()

  get: (id) -> @_modelize(@_collection.get(id))

  getRelationshipView: (object, relationship) ->
    viewName = "#{relationship.type}_#{relationship.name}_#{relationship.inverse}:#{object.getId()}"
    collectionName = collectionNameForRelationship(object, relationship)
    view = @_context.getCollection(collectionName).getCollection().getDynamicView(viewName)
    unless view?
      view = @_context.getCollection(collectionName).getCollection().addDynamicView(viewName, no)
      switch relationship.type
        when 'many_one'
          query = {}
          query["#{relationship.inverse}_id"] = object.getId()
          view.applyFind(query)
        when 'many_many' then throw 'Not implemented yet'
      if _(relationship.sort).isArray() and relationship.sort.length is 1
        view.applySimpleSort(relationship.sort[0][0], relationship.sort[0][1])
      else if _(relationship.sort).isArray()
        view.applySortCriteria(relationship.sort)
      else if _(relationship.sort).isFunction()
        view.applySort(relationship.sort)
    view.modelize = =>
      @_modelize(view.data())
    view.rematerialize()

  query: () ->
    query = @_collection.chain()
    data = query.data
    query.data = () =>
      @_modelize(data.call(query))
    query.first = () => @_modelize(data.call(query)[0])
    query.first = () =>
      d = data.call(query)
      @_modelize(d[d.length - 1])
    query.all = query.data
    query.count = () -> data.call(query).length
    query

  getCollection: () -> @_collection

  _modelize: (data) ->
    return null unless data?
    modelizeSingleItem = (item) =>
      Class = ledger.database.Model.AllModelClasses()[item.objType]
      new Class(@_context, item)
    if _.isArray(data)
      (modelizeSingleItem(item) for item in data when item?)
    else
      modelizeSingleItem(data)

  refresh: (model) ->
    model._object = @_collection.get model.getId()
    model

class ledger.database.contexts.Context extends EventEmitter

  constructor: (db) ->
    @_db = db
    @_collections = {}
    for collection in @_db.getDb().listCollections()
      @_collections[collection.name] = new Collection(@_db.getDb().getCollection(collection.name), @)
      @_listenCollectionEvent(@_collections[collection.name])
    @initialize()

  initialize: () ->
    modelClasses = ledger.database.Model.AllModelClasses()
    for className, modelClass of modelClasses
      collection = @getCollection(className)
      collection.getCollection().DynamicViews = []
      collection.getCollection().ensureIndex(index) for index in modelClass._indexes if modelClass.__indexes?
    try
      new ledger.database.MigrationHandler(@).applyMigrations()
    catch er
      e er

  getCollection: (name) ->
    collection = @_collections[name]
    unless collection?
      collection = new Collection(@_db.getDb().addCollection(name), @)
      @_collections[name] = collection
      @_listenCollectionEvent(collection)
    collection

  notifyDatabaseChange: () ->
    @_db.scheduleFlush()

  close: ->

  _listenCollectionEvent: (collection) ->
    collection.getCollection().on 'insert', (data) =>
      @emit "insert:" + data['objType'].toLowerCase(), @_modelize(data)
    collection.getCollection().on 'update', (data) =>
      @emit "update:" + data['objType'].toLowerCase(), @_modelize(data)
    collection.getCollection().on 'delete', (data) =>
      @emit "delete:" + data['objType'].toLowerCase(), @_modelize(data)

  _modelize: (data) -> @getCollection(data['objType'])?._modelize(data)

_.extend ledger.database.contexts,

  open: () ->
    ledger.database.contexts.main = new ledger.database.contexts.Context(ledger.database.main)

  close: () ->
    ledger.database.contexts.main?.close()
