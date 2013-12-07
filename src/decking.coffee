fs            = require "fs"
child_process = require "child_process"
async         = require "async"
uuid          = require "node-uuid"
DepTree       = require "deptree"
read          = require "read"

Docker = require "dockerode"
docker = new Docker
  socketPath: "/var/run/docker.sock"

logger = process.stdout
log = (data) -> logger.write "#{data}\n"

module.exports =
class Decking
  constructor: (options) ->
    {@command, @args} = options

    @config = @loadConfig "./decking.json"

  processConfig: (config) ->
    for name, details of config.containers
      if typeof details is "string"
        details = config.containers[name] =
          image: details

      details.dependencies = [] if not details.dependencies
      details.aliases = []
      details.name = name
      for dependency,i in details.dependencies
        [name, alias] = dependency.split ":"
        details.dependencies[i] = name
        details.aliases[i] = alias

    return config

  parseConfig: (data) -> JSON.parse data

  loadConfig: (file) ->
    log "Loading package file..."
    @processConfig @parseConfig fs.readFileSync file

  commands:
    build: (done) ->
      [image] = @args

      if image is "all"
        images = (key for key,val of @config.images)

        async.eachSeries images,
        (image, callback) =>
          @build image, callback
        , done
      else
        @build image, done

    create: (done) ->
      # create a container based on metadata
      # for now due to remote API limitations this
      # is going to be a `run` followed quickly by a `stop`
      [cluster] = @args
      @create cluster, done

    start: (done) ->
      [cluster] = @args
      @start cluster, done

    stop: (done) ->
      [cluster] = @args
      @stop cluster, done

    status: (done) ->
      [cluster] = @args
      @status cluster, done

  start: (cluster, done) ->
    target = getCluster @config, cluster

    iterator = (details, callback) ->
      name = details.name
      container = docker.getContainer name
      container.inspect (err, data) ->
        if not data.State.Running
          logAction name, "starting..."
          container.start callback
        else
          logAction name, "skipping (already running)"
          callback null

    resolveOrder @config, target, (list) ->

      validateContainerPresence list, (err) ->
        return done err if err

        async.eachSeries list, iterator, done


  stop: (cluster, done) ->
    target = getCluster @config, cluster

    iterator = (details, callback) ->
      name = details.name
      container = docker.getContainer name
      container.inspect (err, data) ->
        if data.State.Running
          logAction name, "stopping..."
          container.stop callback
        else
          logAction name, "skipping (already stopped)"
          callback null

    resolveOrder @config, target, (list) ->

      validateContainerPresence list, (err) ->
        return done err if err

        async.eachSeries list, iterator, done

  status: (cluster, done) ->
    target = getCluster @config, cluster

    iterator = (details, callback) ->
      name = details.name
      container = docker.getContainer name
      container.inspect (err, data) ->
        if err # @TODO inspect
          logAction name, "does not exist"
        else if data.State.Running
          logAction name, "running" # @TODO more details
        else
          logAction name, "stopped"

        callback null

    # true, we don't care about the order of a cluster,
    # but we *do* care about implicit containers, so we have to run this
    # for now. Should split the methods out
    resolveOrder @config, target, (list) -> async.eachLimit list, 5, iterator, done

  create: (cluster, done) ->
    # @TODO use the remote API when it supports -name and -link
    # @TODO check the target image exists locally, otherwise
    # `docker run` will try to download it. we want to take care
    # of dependency resolution ourselves
    target = getCluster @config, cluster

    commands = []

    fetchIterator = (details, callback) ->
      name = details.name
      container = docker.getContainer name

      command =
        name: name
        container: container

      container.inspect (err, data) ->
        if not err
          command.exists = true
          commands.push command
          return callback null

        # basic args we know we'll need
        cmdArgs = ["docker", "run", "-d", "-name", "#{name}"]

        # this starts to get a bit messy; we have to loop over
        # our container's options and using a closure bind a
        # function to run against each key/val - a function which
        # can potentially be asynchronous
        # we bung all these closures in an array which we *then*
        # pass to async. can't just use async.each here as that
        # only works on arrays
        run = []
        for key,val of details
          # don't need to bind 'details', it doesn't change
          do (key, val) ->
            # run is going to be fed into async.series, it expects
            # to only fire a callback per iteration...
            run.push (done) -> getRunArg key, val, details, done

        # now we've got our array of getRunArg calls bound to the right
        # variables, run them in order and add the results to the initial
        # run command
        async.series run, (err, results) ->
          cmdArgs = cmdArgs.concat result for result in results
          cmdArgs.push details.image

          command.exec = cmdArgs.join " "
          commands.push command

          callback null

    createIterator = (command, callback) ->
      name = command.name

      if command.exists
        # already exists, BUT it might be a dependency so it needs starting
        #log "Container #{name} already exists, skipping..."
        # @TODO check if this container has dependents or not...
        logAction name, "already exists - running in case of dependents"
        return command.container.start callback

      logAction name, "creating..."

      child_process.exec command.exec, callback

    stopIterator = (details, callback) ->
      container = docker.getContainer details.name
      container.stop callback

    resolveOrder @config, target, (list) ->
      async.eachSeries list, fetchIterator, ->
        async.eachSeries commands, createIterator, ->
          # @FIXME hack to avoid ghosts with quick start/stop combos
          setTimeout ->
            async.eachLimit list, 5, stopIterator, done
          , 500

  build: (image, done) ->

    throw new Error("Please supply an image name to build") if not image

    log "Looking up build data for #{image}"

    target = @config.images[image]

    throw new Error("Image #{image} does not exist in decking.json") if not target

    targetPath = "#{target}/Dockerfile"

    log "Building image #{image} from #{targetPath}"

    # @TODO for now, always assume we want to build from a Dockerfile
    # @TODO need a lot of careful validation here
    fs.createReadStream(targetPath).pipe fs.createWriteStream("./Dockerfile")

    options =
      t: image

    tarball = "/tmp/decking-#{uuid.v4()}.tar.bz"
    log "Creating tarball to upload context..."

    child_process.exec "tar -cjf #{tarball} ./", ->

      fs.unlink "./Dockerfile", (err) -> log "[WARN] Could not remove Dockerfile" if err

      log "Uploading tarball..."
      docker.buildImage tarball, options, (err, res) ->

        res.pipe process.stdout

        res.on "end", ->
          log "Cleaning up..."
          fs.unlink tarball, done


  execute: (done) ->
    fn = @commands[@command]

    throw new Error "Invalid argument" if typeof fn isnt "function"

    log ""

    return fn.call this, (err) -> throw err if err

maxNameLength = 0
logAction = (name, message) ->
  pad = (maxNameLength + 1) - name.length

  log "#{name}#{Array(pad).join(" ")}  #{message}"

resolveOrder = (config, cluster, callback) ->
  containerDetails = {}

  for containerName in cluster
    container = config.containers[containerName]
    containerDetails[containerName] = container

    # some dependencies might not be listed in the cluster but still need
    # to be resolved
    for dependency in container.dependencies
      if not containerDetails[dependency]
        containerDetails[dependency] = config.containers[dependency]

  depTree = new DepTree
  for name, details of containerDetails
    depTree.add name, details.dependencies
    # @NOTE while we're here, work out the longest name in the cluster (dirty)
    maxNameLength = name.length if name.length > maxNameLength

  list = (containerDetails[item] for item in depTree.resolve())

  callback list

validateContainerPresence = (list, done) ->
  iterator = (details, callback) ->
    name = details.name
    container = docker.getContainer name
    container.inspect callback

  async.eachSeries list, iterator, done

getRunArg = (key, val, object, done) ->
  arg = []

  switch key
    when "env"
      # we need to loop through all the entries asynchronously
      # because if we get an ENV_VAR=- format (the key being -) then
      # we'll prompt for the value
      iterator = (v, callback) ->
        [key, value] = v.split "="

        # first thing's first, try and substitute a real process.env value
        if value is "-" then value = process.env[key]

        # did we have one? great! bail early with the updated value
        if value
          arg = [].concat arg, ["-e #{key}=#{value}"]
          return callback null

        # if we got here we still don't have a value for this env var, so
        # we need to ask the user for it
        options =
          prompt: "#{object.name} requires a value for the env var '#{key}':"

        read options, (err, value) ->
          arg = [].concat arg, ["-e #{key}=#{value}"]
          return callback null

      return async.eachSeries val, iterator, (err) -> done err, arg

    when "dependencies"
      for v,k in val
        # we trust that the aliases array has the correct matching
        # indices here such that alias[k] is the correct alias for dependencies[k]
        alias = object.aliases[k]
        arg = [].concat arg, ["-link #{v}:#{alias}"]

    when "port"
      arg = [].concat arg, ["-p #{v}"] for v in val

    when "mount"
      arg = [].concat arg, ["-v #{v}"] for v in val

  return done null, arg

getCluster = (config, cluster) ->
  throw new Error "Please supply a cluster name" if not cluster

  target = config.clusters[cluster]

  throw new Error "Cluster #{cluster} does not exist in decking.json"  if not target

  return target
