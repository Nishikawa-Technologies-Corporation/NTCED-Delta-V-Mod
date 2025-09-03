extends "res://NTCED Parts Pack/weapons/drone-plant.patch.gd"

export (String, "none", "kinetic", "mpu") var advancedFunction = "none"

# How many independant drone streams the drone plant will handle
export (int, 1, 1000) var droneAmount = 1
# Patches in the functionality of the `currentTargetBias` setting.
# This is present but non-functional on vanilla launchers
export (bool) var patchCurrentTargetBias = false
# Enable the yeet protocol, based on the mod of the same name
export (bool) var yeetProtocol = false

# Section for kinetics
export var kineticAdjust = 1.0
export var massLimit = 8.0
export var massUpperLimit = 25000.0
export var iffRequired = 0.5

# Section for MPU
export (float) var refineRate = 10.0
export (float) var lostMass = 1.0
export (float, 0, 1) var remassEfficiency = 0.0
export (float, 0, 1) var mineralEfficiency = 0.1
# Why is there so much for the MPU
var dustScene := preload("res://NTCED Parts Pack/sfx/drone-dust-persistent.tscn")
var calamityScene := preload("res://NTCED Parts Pack/sfx/drone-calamity.tscn")
var dustEmitters := []
var targetLaunchers := []
var returningDrones := []

# The array versions of vanilla components
var droneTargets := []
#onready var target = null
var droneLaunchers := []
#onready var drones = $DroneLaunchManager
var playerLasers := []
#onready var playerLaser = $Laser
# Hashes of the launcher nodes for faster SANBUS checks
var launcherHashes := []

# Generate a new laser AudioStreamPlayer
func newLaser():
	var laser := AudioStreamPlayer.new()
	laser.set_script(playerLaser.get_script())
	laser.stream = playerLaser.stream
	laser.volume_db = playerLaser.volume_db
	laser.bus = playerLaser.bus
	playerLasers.append(laser)
	add_child(laser)

# Generate a new DroneLaunchManager
func newLauncher(idx, returning := false):
	var launcher = drones.duplicate()
	launcher.disconnect("droneHit", self, "_on_DroneLaunchManager_droneHit")
	launcher.connect("droneHit", self, "_on_DroneLaunchManager_droneHit", [idx, returning])
	launcher.drones = dronesPerSecond
	if not returning: droneLaunchers.append(launcher)
	else: targetLaunchers.append(launcher)
	add_child(launcher)

func newDust():
	var emitter := dustScene.instance()
	dustEmitters.append(emitter)
	add_child(emitter)

func _ready():
# Update our scan power draw for how many scans we run
	scanPowerDraw *= droneAmount
# Change our drone function if an advanced function is set
	if advancedFunction != "none":
		droneFunction = advancedFunction
# Set our collision layers for the drone types
	if droneFunction == "kinetic":
		DronePickupArea.collision_mask = 0b00000000000000000001011000000011
	else:
		DronePickupArea.collision_mask = 0b00000000000000000000000000000001
# Disable physics so we can 'override' it with our own
	droneLaunchers.append(drones)
	playerLasers.append(playerLaser)
	droneTargets.append(null)
# Spawn extra nodes for the extra drones
	for i in droneAmount-1:
		newLauncher(i+1)
		newLaser()
		droneTargets.append(null)
# Setup extras for MPU drones
	if droneFunction == "mpu":
		for i in droneAmount:
			newDust()
			newLauncher(i, true)
			returningDrones.append(0.0)
# Pre-hash our launcher nodes if we are using SANBUS
	if sanbus:
		for launcher in droneLaunchers:
			launcherHashes.append(hash(launcher))

func _setEnabled(how:bool):
	enabled = how
	DronePickupArea = self.get_node_or_null("DronePickupArea")
# Disable the monitoring area if we're repair drones
	if droneFunction == "repair":
		DronePickupArea.monitoring = false
	else: DronePickupArea.monitoring = how
# Clear SANBUS when module is disabled
	if not how:
		for launcher in droneLaunchers:
			ship.clearSystemTarget(launcher)

# Sort the targets based on how desireable they are
func sortTargets(a, b):
	return a[1] > b[1]

# Check if the target was targeted last check, and assign it to the same launcher if it was
func wasTargetedLast(target, pastTargets: Array) -> bool:
	var lastPos = pastTargets.find(target)
# If the target was targeted last check
	if lastPos != -1:
	# If something else is already in that slot
		if droneTargets[lastPos]:
		# Shuffle the targets so the drones target their previous target
			var nullPos = droneTargets.find_last(null)
			droneTargets[nullPos] = droneTargets[lastPos]
			droneTargets[lastPos] = target
			return true
	# If the previous slot is empty, have it target the same one
		else:
			droneTargets[lastPos] = target
			return true
# Continue if it wasn't targeted
	else: return false

# Check if we have valid sanbus lock
func validSanbusTarget(target:Node) -> bool:
# Hash the target node for comparison with the SANBUS
	var targetHash := hash(target)
# If the SANBUS does have that node targeted
	if sanbus and targetHash in ship.systemTargets.keys():
	# If the node is not one of our launchers
		if not ship.systemTargets[targetHash] in launcherHashes:
		# It's not a free target
			return false
	return true

func scanForTargets(delta):
	scanProcess += delta
	if scanProcess > scanEvery:
		scanProcess = 0

		match droneFunction:

		# If this is a repair drone, just check the status of the ship
			"repair":
				var systems = ship.getSystems()
				for k in systems:
					var system = systems[k]
					for d in system.damage:
						if d.current > d.maxRaw * (1 - repairLimit):
							# If it needs repairs, target with all launchers
								droneTargets.fill(ship)
								return
			# If it does not need repairs, target nothing
				droneTargets.fill(null)
				return

		# Check for valid targets to murder
			"kinetic":
				var dmax = getRangeMax() * 10
				var space = ship.get_parent()

				var pastTargets : Array = droneTargets.duplicate()
				var possibleTargets : Array = targets.duplicate()
				var validTargets := []
				droneTargets.fill(null)
				

				for t in possibleTargets:
					if Tool.claim(t):
						if "inCargoHold" in t and t.inCargoHold:
							Tool.release(t)
							continue
						if "equipment" in t and t.equipment:
							Tool.release(t)
							continue
						if not validSanbusTarget(t):
							Tool.release(t)
							continue

						var test = t
						if test != null and "docked" in test and test.docked != null:
							test = test.docked
						while test != null and test.get_parent() != space:
							test = test.get_parent()
						if test == ship:
							Tool.release(t)
							continue
					# Score each valid target by how much we want to kill them
						var score = 1 - clamp(global_position.distance_to(t.global_position) / dmax, 0, 1)
						if test and test.has_method("aiGetDispositionTowards"):
							var disp = ship.aiGetDispositionTowards(test)
							if disp.hostility >= iffRequired:
								score += disp.support - max(disp.hostility, disp.fear)
							else: continue
						if patchCurrentTargetBias and t in pastTargets:
							score *= currentTargetBias
						validTargets.append([t, score])
					Tool.release(t)
			# Sort our targets and assign them to launchers
				validTargets.sort_custom(self, "sortTargets")
				for key in validTargets:
				# Check if there's an empty slot
					if droneTargets.has(null):
						var t = key[0]
					# If the target was not previously targeted, set the target
						if !wasTargetedLast(t, pastTargets):
							droneTargets[droneTargets.find(null)] = t
				# If there is no empty slot, we're done sorting
					else: return

		# Check if valid mineral target
			"tug", "haul", "mpu":
				var dmin = getRangeMin() * 10
				var dmax = getRangeMax() * 10
				var space = ship.get_parent()

				var shipQueue : Array = ship.droneQueue
				var possibleTargets : Array = targets.duplicate()
				var pastTargets : Array = droneTargets.duplicate()
				droneTargets.fill(null)

				var viableTargets := []
				var priorityTargets := []

			# Add the priority queue targets to the list
				if shipQueue:
					for t in shipQueue:
						# Make sure we don't double up on them
						if not possibleTargets.has(t):
							possibleTargets.append(t)

				for t in possibleTargets:
					if Tool.claim(t):
						# Check if it's a valid target
						if t.get_parent() != space:
							Tool.release(t)
							continue
						if "inCargoHold" in t and t.inCargoHold:
							Tool.release(t)
							continue
						if not t is RigidBody2D:
							Tool.release(t)
							continue
						if t == ship.autopilotVelocityOffsetTarget:
							Tool.release(t)
							continue
						var dist = global_position.distance_to(t.global_position)
						if dist > dmax or dist < dmin:
							Tool.release(t)
							continue
						if mineralTargetting and not ship.isValidMineralTarget(t, mineralConfig):
							if not yeetProtocol:
								Tool.release(t)
								continue
						# Check if something else has a sanbus lock
						if not validSanbusTarget(t):
							Tool.release(t)
							continue

						# Check if the target needs work done on it
						var check := 0.0
						var toPass := 0.0
						match droneFunction:
							"haul":
								var desired := desiredVelicityFor(t)
								check = t.mass * pow((desired - t.linear_velocity).length(), 2) / dist
								toPass = minEnergyToTarget
							"tug":
								var v = t.linear_velocity.length()
								check = t.mass * pow(v, 2)
								toPass = minEnergyToTarget
							"mpu":
								var h = hash(t)
								if h in ship.identifiedObjects:
									check = ship.identifiedObjects[h][1]
								else:
									check = 1

						if patchCurrentTargetBias and t in pastTargets:
							check *= currentTargetBias
						# If the target passes the check, add it to the list it belongs to
						if check > toPass:
							if t in shipQueue:
								priorityTargets.append(t)
							else:
								viableTargets.append([t, check])
						Tool.release(t)

				for t in priorityTargets:
				# Check if there's an empty slot
					if droneTargets.has(null):
					# If the target was not previously targeted, set the target
						if !wasTargetedLast(t, pastTargets):
							droneTargets[droneTargets.find_last(null)] = t
				# If there is no empty slot, we're done sorting
					else: return

			# Sort our targets by how much work they need done to them
				viableTargets.sort_custom(self, "sortTargets")
				for key in viableTargets:
				# Check if there's an empty slot
					if droneTargets.has(null):
						var t = key[0]
					# If the target was not previously targeted, set the target
						if !wasTargetedLast(t, pastTargets):
							droneTargets[droneTargets.find(null)] = t
				# If there is no empty slot, we're done sorting
					else: return
	else :
	# Clear any targets that entered the cargo hold this frame
		for idx in droneTargets.size():
			target = droneTargets[idx]
			if Tool.claim(target):
				if "inCargoHold" in target and target.inCargoHold:
					stopLauncher(idx)
				Tool.release(target)

func __physics_process(delta):
	if Tool.claim(ship):
		readpower = 0
		if enabled and ship.drawEnergy(scanPowerDraw * delta) >= scanPowerDraw * delta * 0.9:
			scanForTargets(delta)
		else:
			droneTargets.fill(null)
			scanProcess = 0

		for idx in droneLaunchers.size():
			target = droneTargets[idx]
			var drones = droneLaunchers[idx]
			var rDrone
			if targetLaunchers.size() < 1:
				rDrone = null
			else:
				rDrone = targetLaunchers[idx]
			var laser = playerLasers[idx]

			drones.sourceVelocity = ship.linear_velocity + launchVector.rotated(global_rotation)
			if drones.laserFiring:
				var energyRequired = delta * powerDraw
				var energy = ship.drawEnergy(energyRequired)
				drones.power = energy / energyRequired > 0.9
				if ship.isPlayerControlled() and drones.power:
					if not laser.playing:
						laser.play()
				else :
					laser.stop()
			else :
				laser.stop()
				drones.power = true
		
			if Tool.objectValid(target):
				firepower = 1

			if firepower > 0 and enabled and not ship.cutscene:
				var energyRequired = delta * lauchPowerDraw
				var energy = ship.drawEnergy(energyRequired)
				if energy / energyRequired > 0.9 and Tool.claim(target):
					if sanbus:
						ship.addSystemTarget(drones, target)
					drones.targetNode = target
					var needDrones = dronesPerSecond * delta * droneWeightKg
					var gotDrones = ship.drawDrones(needDrones)
					if gotDrones >= needDrones:
						drones.emitting = true
						readpower += firepower
						if not playing and ship.isPlayerControlled():
							playerAudioFire.play()
							playing = true
					else :
						drones.emitting = false
						stopLauncher(idx)
						
					if ship.isPlayerControlled():
						CurrentGame.logEvent("LOG_EVENT_DIVE", {"LOG_EVENT_DETAILS_DRONE":gotDrones})
					Tool.release(target)
				firepower = 0
			else :
				drones.emitting = false
				stopLauncher(idx)
				ship.clearSystemTarget(drones)

		# Terrible method for handling returning drones
			if rDrone:
				if target:
					rDrone.global_position = target.global_position
					rDrone.sourceVelocity = target.linear_velocity
				if rDrone.laserFiring:
					var energyRequired = delta * powerDraw
					var energy = ship.drawEnergy(energyRequired)
					rDrone.power = energy / energyRequired > 0.9
					if ship.isPlayerControlled() and rDrone.power:
						if not laser.playing:
							laser.play()
					else :
						laser.stop()
				else :
					laser.stop()
					rDrone.power = true

				if enabled and not ship.cutscene:
					var energyRequired = delta * lauchPowerDraw
					var energy = ship.drawEnergy(energyRequired)
					if energy / energyRequired > 0.9:
						rDrone.targetNode = ship
						if returningDrones[idx] >= delta:
							returningDrones[idx] -= delta
							rDrone.emitting = true
						else:
							rDrone.emitting = false
				else:
					rDrone.emitting = false

			idx += 1

		Tool.release(ship)

# Overriden for yeet protocol
func desiredVelicityFor(target:RigidBody2D)->Vector2:
	if yeetProtocol and not ship.isValidMineralTarget(target, mineralConfig):
		return yeetVelocityFor(target)
	else:
		return .desiredVelicityFor(target)

# Calculates vector away from ship for yeeting
func yeetVelocityFor(target:RigidBody2D)->Vector2:
	var toShip = ship.global_position - target.global_position
	var vAwayFromShip = ship.linear_velocity - toShip.normalized() * haulVelocity * 3.0
	return vAwayFromShip

# Hacky way to use the existing code with multiple targets
func _on_DroneLaunchManager_droneHit(pt, delta, drones, idx := 0, returning := false):
	target = droneTargets[idx]
	match droneFunction:
		"kinetic":
			if Tool.claim(target):
				if target.global_position != null:
					var distance = pt.distance_to(target.global_position)
					if distance < hitDeadZone:
					# Get vector away from ship and calculate force
						var impulse := yeetVelocityFor(target).normalized()
						impulse *= delta * drones * droneTugPower
					# Apply force and damage to target
						target.apply_impulse(Vector2(0, 0), impulse)
						target.addIntegratedDamage(droneLaunchers[idx], 
						impulse.length() * kineticAdjust, target.global_position)
					else :
						Debug.l("kinetic drone target out of range: %f" % distance)
				Tool.release(target)
		"mpu":
			if Tool.claim(target):
				if "mineralContent" in target and "fillerContent" in target:
					if target.mass > lostMass / 1000:

						if not returning:
						# When drones hit the rock, make dust and queue returning drones
							returningDrones[idx] += delta
							makeDust(idx)

						else:
							var newMass : float = target.mass
							for mineral in target.composition:
							# Calculate how much of each mineral we can take from the target
								var amount = (target.composition[mineral] / target.mass) 
								amount *= (refineRate * delta) / 1000
								amount = clamp(amount, 0, target.composition[mineral])

								target.composition[mineral] -= amount
								newMass -= amount

							# Add remass to ship
								if mineral == "H2O":
									amount *= remassEfficiency * 1000
									ship.reactiveMass = clamp(amount + ship.reactiveMass, 0, ship.reactiveMassMax)
							# Add minerals to storage
								else:
									amount *= mineralEfficiency * 1000
									var got = ship.addProcessedCargo(mineral, amount, ship.getProcessedCargoCapacity(mineral))

						# This is *supposed* to calculate the volume of a sphere where the original mass of the chunk 
						# would have a radius of one, assuming mass and volume are directly proportional
							var massScale : float = newMass / target.mass * 4.18879 # EVIL MAGIC NUMBER
						# This is *supposed* to calculate a scaled chunk, where one is the previous radius
							var radiusScale : float = pow((3 * (massScale / (4 * PI))), 1.0/3.0)
						# I'm going to be entirely honest, i have no idea if this is accurate
							target.getCollider().scale = clamp(target.getCollider().scale * radiusScale, 0.5, 1.0)
							target.sprite.scale *= radiusScale
							target.mass = newMass
					else:
					# Make dust and destroy the rock
						makeDust(idx, true)
						target.collision_mask = 0
						target.collision_layer = -2147483648
						Tool.deferCallInPhysics(Tool, "remove", [target])

				Tool.release(target)
		_:
			._on_DroneLaunchManager_droneHit(pt, delta, drones)

func stopLauncher(idx:int):
	droneTargets[idx] = null
	droneLaunchers[idx].emitting = false
	if droneFunction == "mpu":
		dustEmitters[idx].emit(false)
#		targetLaunchers[idx].emitting = false
		returningDrones[idx] = 0.0

func _on_DronePickupArea_body_entered(body):
	match droneFunction:
		"kinetic":
			if body == ship:
				return 
	
			if body is RigidBody2D:
				if body.has_method("isPlayerControlled"):
					pass
				else :
					if body.get_parent() == ship.get_parent():
						if body.mass <= massLimit:
							return 
						if body.mass >= massUpperLimit:
							return 

				targets.append(body)
		_:
			._on_DronePickupArea_body_entered(body)

func _on_DronePickupArea_body_exited(body):
	match droneFunction:
		"kinetic":
			droneTargets[droneTargets.find(body)] = null
			targets.erase(body)
		_:
			._on_DronePickupArea_body_exited(body)

func makeDust(idx, isCalamity := false):
	var emissionRadius = target.getCollider().shape.radius * target.getCollider().scale
# Teleport our magic dust spawner and emit dust
	dustEmitters[idx].process_material.emission_sphere_radius = emissionRadius
	dustEmitters[idx].global_position = target.global_position
	dustEmitters[idx].emit(true)

# If the chunk is destroyed, spawn extra particles
	if isCalamity:
		var dustInstance := calamityScene.instance()
		add_child(dustInstance)
		dustInstance.explosiveness = 0.5
		dustInstance.global_position = target.global_position
		dustInstance.process_material.emission_sphere_radius = emissionRadius
		dustInstance.one_shot = true
		dustInstance.emitting = true
