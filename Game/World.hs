{-# LANGUAGE FlexibleContexts, TemplateHaskell, Arrows, NamedFieldPuns, Rank2Types #-}
module Game.World 
	(
	-- * World
	  WorldWire, WorldSession, WorldContext
	, World, WorldManager, WorldDelta

	-- * To remove
	, wmPlayerActions
	, applyDelta

	, wPlayerId, wPlayerPos
	, wBoulderId, wBoulderPos
	, wPhysics

	, newWorld, newWorldManager, newWorldFromTiled
	, testwire
	) where

import Debug.Trace
import Control.Concurrent

import qualified Data.Map as Map
import qualified Data.Set as Set
import Control.Monad.RWS
import Control.Monad.Identity
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.State
import Control.Monad
import Data.Maybe

import qualified Data.Binary as B

import Control.Wire
import qualified Control.Wire as W
import Control.Wire.Unsafe.Event
import qualified Prelude as P
import Prelude hiding ((.), until)

import Control.Lens
import qualified Control.Lens as L
import Game.World.Objects
import Game.Collision

import Data.Tiled
import Game.World.Import.Tiled

import Game.Input.Actions as A

import Game.World.Types

import Game.World.Delta

data WorldManager = WorldManager
	{ _wmObjects :: ObjectIds 
	, _wmObjectsInUse :: Map.Map ObjectId ObjectId -- Map objectInUse owningObject
 	, _wmObjectRefs :: Map.Map ObjectId ObjectIds
	, _wmNextObjectId :: ObjectId
	, _wmPlayerActions :: Map.Map PlayerId InputActions
	} deriving (Show, Eq)

makeLenses ''WorldManager

--type WorldContext = RWS World WorldDelta WorldManager
type DebugWorldContext = RWST World WorldDelta WorldManager IO
type WorldContext = DebugWorldContext

--type WorldWire a b = Wire (Timed NominalDiffTime ()) () WorldContext a b
type DebugWire a b = Wire (Timed NominalDiffTime ()) () DebugWorldContext a b
type WorldWire a b = DebugWire a b 
type WorldSession = Session IO (Timed NominalDiffTime ())

newWorldManager = WorldManager
	{ _wmObjects = Set.empty
	, _wmObjectsInUse = Map.empty
	, _wmObjectRefs = Map.empty
	, _wmNextObjectId = 1
	, _wmPlayerActions = Map.empty
	}

newWorldFromTiled :: TiledMap -> IO (World, WorldManager) -- io due to debug wire
newWorldFromTiled tiledMap = do
	let world = newWorld 
		{ _wTileBoundary = tiledMap^.mapTileSize
		}
	(worldManager, worldDelta) <- execRWST (
			stepWire initWire (Timed 0 ()) (Right ())
		) world newWorldManager

	let world' = applyDelta world worldDelta
	return (world', worldManager)

	where
		Just player1Obj = queryObject tiledMap "Player1"
		Just player2Obj = queryObject tiledMap "Player2"
		Just dinoObj = queryObject tiledMap "Dino"
		Just beeObj = queryObject tiledMap "Bee"

		wallPositions = mapWallPositions tiledMap
		boulders = mapBoulders tiledMap

		--genWalls :: [(Float, Float)] -> WorldWire a b
		genWalls [] = returnA
		genWalls (wallPos:walls) = proc input -> do
			spawnWallAt wallPos -< input
			genWalls walls -< input
			returnA -< input

		genBoulders [] = returnA
		genBoulders (boulder:boulders) = proc input -> do
			spawnBoulderAt (boulder^.objectPos tiledMap) (boulder^.objectName._Just) -< input
			genBoulders boulders -< input
			returnA -< input

		initWire = proc input -> do
			_ <- spawnPlayerAt "Neira" (player1Obj^.objectPos tiledMap) -< input
			_ <- spawnPlayerAt "TheGhost" (player2Obj^.objectPos tiledMap) -< input
			_ <- spawnPlayerAt "Dino" (dinoObj^.objectPos tiledMap) -< input
			_ <- spawnPlayerAt "Bee" (beeObj^.objectPos tiledMap) -< input

			-- Initialize: need maybe check in client to remove this TODO
			_ <- animate (defaultCharacterAnim (0, 0)) -< 1
			_ <- animate (defaultCharacterAnim (0, 0)) -< 2
			_ <- animate (defaultCharacterAnim (0, 0)) -< 3
			_ <- animate (defaultCharacterAnim (0, 0)) -< 4

			_ <- genWalls wallPositions -< input
			_ <- genBoulders boulders -< input

			returnA -< ()

colAdd v Nothing = Just $ v
colAdd v (Just v2) = Just $ v `mappend` v2


applyDelta :: World -> WorldDelta -> World
applyDelta w wd = collisions
	where
		newWalls = w { _wWalls = foldr (\d -> Map.insert (wallId d) d) (_wWalls w) (_wdWallsAdd wd) }
		newObjects = newWalls & wObjects .~ foldr (\o -> Map.insert (o^.objId) o) (w^.wObjects) (wd^.wdObjectsAdd)
		newPlayers = newObjects { _wPlayers = foldr (\p -> Map.insert (playerId p) p) (_wPlayers newObjects) (_wdPlayerAdd wd) }
		newBoulders = newPlayers & wBoulders %~ (\boulderMap-> foldr (\b -> Map.insert (boulderId b) b) boulderMap (wd^.wdBouldersAdd))
		positions = newBoulders { _wPositions = foldr (\(k, v) m -> Map.alter (alterPos v) k m) (_wPositions newBoulders) (Map.toList . deltaPos . _wdPositionsDelta $ wd) }
		
		physics = positions & wPhysics %~ (\physicsMap -> foldr (\(k, v) -> Map.alter (alterPhysics v) k) physicsMap (Map.toList . containerData $ wd^.wdPhysicsDelta))
		--positions2 = positions & wPositions = foldr (\objectPhysics ->
			--Map.alter (alterPos ))
		collidables = physics { _wCollisionManager = execState (do
				mapM_ cmAddStatic [newCollidable oId (newBoundary (objectPos oId) (w^.wTileBoundary._1)) | oId <- map wallId (_wdWallsAdd wd)]
				mapM_ cmAddFloating [newCollidable oId (newBoundary (objectPos oId) (w^.wTileBoundary._1)) | oId <- map playerId (_wdPlayerAdd wd)]
			) (_wCollisionManager physics) }
		floatingCollidables = collidables { _wCollisionManager = execState (
				mapM_ ((\oId -> cmUpdateFloating oId (objectPos oId)) . fst) (Map.toList (deltaPos $ wd^.wdPositionsDelta))
			) (_wCollisionManager collidables) }

		anims = floatingCollidables & wAnimations .~ Map.union (wd^.wdAnimations) (w^.wAnimations) -- left-biased
		cb = anims & wCollisionCallbacks .~ Map.union (wd^.wdCollisionCallbacks) (anims^.wCollisionCallbacks)

		collisionEvents = cb & wCollisionEvents .~ foldr (\(k, v) m -> Map.alter (colAdd [v]) k m) Map.empty (wd^.wdCollisionEvents) 


		-- overwrite old ones
		collisions = collisionEvents { _wCurrentCollisions = containerData $ wd^.wdCollisions }

		objectPos oId = (positions ^. wPositions) Map.! oId

		alterPhysics op Nothing = Just op
		alterPhysics (ObjectPhysics a1 v1) (Just (ObjectPhysics a2 v2)) = Just $ ObjectPhysics a1 (v1 `mappend` v2)
		--doorControllers = positions { wDoorControllers = foldr (\dc -> Map.insert (doorControllerId dc) dc) (wDoorControllers positions) (wdDoorControllers wd) }

--validateWorldDelta :: WorldDelta -> Bool

-- TODO
-- fix collisions (reset positions)
--fixWorldDelta :: World -> WorldDelta -> WorldDelta

alterPos (x, y) Nothing = Just (x, y)
alterPos (x, y) (Just (x', y')) = Just (x + x', y + y')

norm x = if abs(x) < 0.0005 then 0 else x/abs(x)
sgn x = norm x

-- FIXME
collisionTransformation :: --(MonadReader World m) 
	 ObjectId
	-> (Float, Float)
	-> WorldContext (Float, Float)
collisionTransformation oId (dx, dy) = do
	cm <- view wCollisionManager
	if cmCanCollide oId cm 
		then do
			-- FIXME: right now objects can jump through other objects if delta is too big
			let ((dx', dy'), collisions) = collisionLoop cm (dx, dy) (sgn dx, sgn dy) []
			Control.Monad.unless (null collisions) $ 
				mapM_ (deltaCollisionEvent oId) collisions
				--colCb <- view wCollisionCallbacks
				--if Map.member oId colCb 
				--	then do
				--		let cb = colCb Map.! oId
				--		lift $ print "Callback"
				--	else return ()

			--scribe wdPositionsDelta $ ObjectPositionDelta $ Map.insert oId dPos Map.empty
			return (dx', dy')
		else
			return (dx, dy)

	where			
		collisionLoop cm (dx, dy) dir@(sx, sy) collisionHappened = 
			if null collisions then
				((dx, dy), collisionHappened)
			else 
				collisionLoop cm (dx - sx * 0.1, dy - sy * 0.1) dir collisions
			where
				collisions = evalState (do
						(px, py) <- cmObjectPos oId
						cmUpdateFloating oId (px+dx, py+dy)
						cmCollisions oId
					) cm

newObject :: MonadState WorldManager m => m ObjectId
newObject = do
	wm <- get 
	let oId = wm^.wmNextObjectId
	wmNextObjectId += 1
	wmObjects .= Set.insert oId (wm^.wmObjects)
	return oId

moveObject :: (Float, Float) -> WorldWire ObjectId ()
moveObject (vx, vy) = mkGen $ \ds oId -> do
	let dt = realToFrac (dtime ds)
	let (dx, dy) = (dt*vx, dt*vy)
	(dx', dy') <- collisionTransformation oId (dx, dy)
	deltaMoveObject oId (dx', dy')
	return (Right (), moveObject (vx, vy))

moveObjects :: WorldWire a ()
moveObjects = mkGen $ \ds _ -> do
	w <- ask
	let dt = realToFrac (dtime ds)
	mapMOf traverse (\oId -> do
			let (ax, ay) = w^.wObjectAccel oId
			let (vx, vy) = w^.wObjectSpeed oId
			--deltaApplyForce oId (ax, ay)
			deltaSpeed oId (ax*dt, ay*dt) -- apply force to speed

			let (dx, dy) = (dt*vx, dt*vy)
			(dx', dy') <- collisionTransformation oId (dx, dy)
			deltaMoveObject oId (dx', dy')
			--deltaMoveObject oId (vx*dt, vy*dt) -- apply speed to pos
			return ()
		) (map fst $ Map.toList $ w^.wPhysics)

	return (Right (), moveObjects)

deaccelObjects :: WorldWire a ()
deaccelObjects = mkGen $ \ds _ -> do
	w <- ask
	let dt = realToFrac (dtime ds)
	mapMOf traverse (\oId -> do
			--let (ax, ay) = w^.wObjectAccel oId
			let (vx, vy) = w^.wObjectSpeed oId
			if abs vx < 0.0005 && abs vy < 0.0005
				then 
					deltaSpeed oId (-vx, -vy)
				else deltaApplyForce oId (-vx/2, -vy/2)
			--deltaMoveObject oId (vx*dt, vy*dt)
			return ()
		) (map fst $ Map.toList $ w^.wPhysics)

	return (Right (), deaccelObjects)

accelObject :: (Float, Float) -> WorldWire ObjectId ()
accelObject (ax, ay) = mkGen $ \ds oId -> do
	let dt = realToFrac (dtime ds)
	deltaApplyForce oId (ax*dt, ay*dt)
	return (Right (), accelObject (ax, ay))

objectCollided :: WorldWire ObjectId (Event ())
objectCollided = mkGenN $ \oId -> do
	w <- ask
	let currentColls = w^.wCurrentCollisions
	return $ if Map.member oId currentColls
		then (Right (Event ()), objectCollided)
		else (Right NoEvent, objectCollided)

moveObjectR :: WorldWire (ObjectId, (Float, Float)) ()
moveObjectR = mkGen $ \ds (oId, (vx, vy)) -> do
	let dt = realToFrac (dtime ds)
	let (dx, dy) = (dt*vx, dt*vy)
	(dx', dy') <- collisionTransformation oId (dx, dy)
	deltaMoveObject oId (dx', dy')
	return (Right (), moveObjectR)

collision :: WorldWire ObjectId (Event [ObjectId])
collision = mkGenN $ \oId -> do
	events <- view wCollisionEvents
	if Map.member oId events 
		then do
			return (Right $ Event $ events Map.! oId, collision)
		else do
			return (Right NoEvent, collision)

spawnObjectAt name pos = mkObjGenWire $ deltaAddObject name pos

spawnObjectAtR :: String -> WorldWire (ObjectId, (Float, Float)) (Event ObjectId)
spawnObjectAtR name = mkGen $ \ds (oId, pos) -> do
	(mx, w') <- stepWire (spawnObjectAt name pos) ds (Right oId)
	return (mx, never)

spawnPlayerAt :: String -> (Float, Float) -> WorldWire a (Event PlayerId)
spawnPlayerAt name pos = mkObjGenWire $ deltaAddPlayer name pos

spawnWallAt pos = mkObjGenWire $ deltaAddWall pos
spawnBoulderAt pos name = mkObjGenWire $ deltaAddBoulder pos name

wireGet getter = mkGenN $ \_ -> do
	result <- magnify getter ask
	case result of 
		Just result -> return (Right result, wireGet getter)
		Nothing -> return (Left (), wireGet getter) 

movingDirectionR :: WorldWire PlayerId (Event (Float, Float))
movingDirectionR = mkGen $ \ds playerId -> do
	wm <- get
	if Map.member playerId (wm^.wmPlayerActions) 
		then do
			let playerActions = asks _wmPlayerActions wm Map.! playerId
			let direction = A.movingDirection playerActions
			case direction of
				(0, 0) -> do
					return (Right NoEvent, movingDirectionR)
				_ -> do
					return (Right (Event direction), movingDirectionR)
		else
			return (Right NoEvent, movingDirectionR)

-- TODO write tests for overlapping dt
animate :: Animation -> WorldWire ObjectId ()
animate anim = mkGen $ \ds oId -> do
	let dt = realToFrac (dtime ds)
	if anim^.animCurrentTime + dt > anim ^. animTime
		then do
			let remaining = realToFrac $ anim^.animCurrentTime + dt - anim^.animTime
			let next = (anim^.animNext) & animCurrentTime .~ 0
			(mx, w') <- stepWire (animate next) (W.Timed (fromRational remaining) ()) (Right oId)
			return (mx, w')
		else do
			let current = anim & animCurrentTime %~ (+) dt
			deltaAnim oId current
			return (Right (), animate current)

animateR :: WorldWire (Animation, ObjectId) ()
animateR = mkGen $ \ds (animation, oId) -> do
	oAnim <- view (wObjectAnim oId)
	if oAnim == animation 
		then do
			-- w' is is animate plus the updated animation
			-- we can drop it since on the next invocation we pass the new state using wObjectName
			(mx, w') <- stepWire (animate oAnim) ds (Right oId)
			return (mx, animateR)
		else do
			(mx, w') <- stepWire (animate animation) ds (Right oId)
			return (mx, animateR)


--player name = mkGenN $ \_ -> do
--	pid <- magnify (wPlayerId name) ask
--	case pid of 
--		Just pId -> return (Right pId, player name)
--		Nothing -> return (Left (), player name)

player name = wireGet (wPlayerId name)
boulder name = wireGet (wBoulderId name) 

nullObject :: ObjectId
nullObject = 0

genLater :: WorldWire (Event ObjectId) (Event ObjectId)
genLater = delay NoEvent


mkObjGenWire :: (ObjectId -> WorldContext ()) -> WorldWire a (Event ObjectId)
mkObjGenWire f = mkGenN (\_ -> do
		oId <- newObject
		f oId
		return (Right (Event oId), never)
	)

userSpeed = 200

inhibitNoEvent = mkGenN $ \e -> do
	case e of
		Event _ ->
			return (Right e, inhibitNoEvent)
		NoEvent ->
			return (Left (), inhibitNoEvent)

playerMovement = proc playerId -> do
	Event (x, y) <- inhibitNoEvent . movingDirectionR -< playerId
	let animation = defaultCharacterAnim (x, y)
	--mul <- pure (-1) . for 3 . asSoonAs . objectCollided <|> pure 1 -< playerId
	--_ <- accelObject (100, 0) . for 3 . after 2 -< playerId
	_ <- animateR -< (animation, playerId)
	_ <- moveObjectR -< (playerId, (-x*userSpeed, y*userSpeed))
	returnA -< ()

playerResetAnimation = animate (defaultCharacterAnim (0, 0))

liftW :: WorldContext r -> WorldWire a r
liftW f = mkGenN $ \_ -> do 
	r <- f
	return (Right r, liftW f)

--t :: World -> Maybe (Float, Float)
--t w = w^.wPlayerPos "Neira"

untilV source = W.until . fmap(\e -> ((), e)) source
colLoop = untilV collision 
	W.--> for 0.1 . liftW (lift $ print "PlayerCollision") . asSoonAs . collision 
	W.--> colLoop

spawnArrowEvent :: WorldWire PlayerId (Event ())
spawnArrowEvent = mkGenN $ \pId -> do
	lift $ print "SpawnArrowEvent"
	actions <- get >>= \wm -> return $ wm^.wmPlayerActions
	let (InputActions playerActions) = actions Map.! pId
	if Set.member ActionSpawnArrow playerActions
		then do
			lift $ print "event ()"
			return (Right $ Event (), spawnArrowEvent)
		else do
			lift $ print "no event"
			return (Right NoEvent, spawnArrowEvent)
	where
		arrowCooldown = 1

spawnObjectAtPlayerLocation = proc playerId -> do
	Just (px, py) <- liftW $ asks (\w -> w^.wPlayerPos "Neira") -< playerId
	objectId <- asSoonAs . spawnObjectAtR "Arrow" -< (playerId, (px + 20, py + 20)) 
	_ <- for 2 . animate arrowAnim -< objectId
	returnA -< ()

spawnArrow = untilV spawnArrowEvent
	W.--> spawnObjectAtPlayerLocation 
	W.--> spawnArrow


testwire = proc input -> do
	_ <- deaccelObjects -< input
	_ <- moveObjects -< input

	playerId <- player "Neira" -< input
	dinoId <- player "Dino" -< input
	beeId <- player "Bee" -< input

	boulderId <- boulder "Boulder1" -< input
	_ <- movement -< playerId

	_ <- animate dinoAnim -< dinoId
	Just (x, y) <- liftW $ asks (\w -> w^.wPlayerPos "Neira") -< input
	Just (x', y') <- liftW $ asks (\w -> w^.wPlayerPos "Dino") -< input
	_ <- moveObjectR -< (dinoId, (userSpeed / 1.5 * norm (x - x'), userSpeed / 1.5 * norm (y - y')))

	_ <- liftW $ deltaSetCollisionCb (\oId w -> w) 1 -< input

	_ <- void (for 1) W.--> animate beeAnim -< beeId

	_ <- colLoop -< playerId

	_ <- spawnArrow -< playerId

	returnA -< ()
	where
		movement = W.until . (fmap (\e ->  ((), e))) movingDirectionR 
			W.--> playerMovement 
			W.--> inhibit () . playerResetAnimation
			W.--> movement

worldLoop w' session' world' state' = do
	(dt, session) <- stepSession session'
	((out, w), worldManager, worldDelta) <- runRWST (
		stepWire w' dt (Right ())
		) world' state'

	let quit = case out of
		Right _ -> False
		Left _ -> True
	return (quit, (w, session), (worldManager, worldDelta))

testWorld :: IO ()
testWorld = do
	let session = clockSession_
	let world = newWorld

	loop world newWorldManager testwire session

	where loop world manager w session = do
		let myManager = manager {
			_wmPlayerActions = Map.insert (1::PlayerId) (newInputAction (ActionMove 0.1 0)) Map.empty
		}
		(quit, (w', session'), (manager', delta)) <- worldLoop w session world myManager
		let world' = applyDelta world delta
		let quit = False
		Control.Monad.unless quit $ loop world' manager' w' session'
