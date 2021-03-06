{-# LANGUAGE TemplateHaskell #-}
module Game.Render 
( clearWindow
, RenderContext
)
where

import Graphics.Rendering.OpenGL
import qualified Graphics.Rendering.OpenGL as GL
import qualified Graphics.UI.GLFW as GLFW

import Game.Render.Map
import Game.Render.Core.Render
import Game.Render.Core.Camera
import Game.Render.Light

import Control.Lens

import Game.Render.Core.Error
import Game.World.Import.Tiled
import Game.World.Common
import Game.World
import Data.Tiled
import Game.Render.World
import Game.Game

data RenderContext = RenderContext
	{ _rcPlayerId :: Int
	, _rcMainProgram :: Program
	--, _rcWorldRenderContext :: WorldRenderContext
	--, _rcLightContext :: LightContext
	--, _rcVisibilityContext :: VisibilityContext
	--, _rcUIRenderContext :: WorldRenderContext
	}
makeLenses ''RenderContext

--newRenderContext :: Game -> IO RenderContext
newRenderContext playerId game = do
	GL.blendFunc $= (GL.SrcAlpha, GL.OneMinusSrcAlpha)
	GL.blend $= GL.Enabled
	logGL "newRenderContext: blend setup failed"

	--let nWorld = game^.gameRenderWorld

	--let uiWorld = mkUIWorld game
	program <- setupShaders "shader.vert" "shader.frag"
	--_ <- uniformInfo program
	--wrc <- newWorldRenderContext nWorld program
	--uirc <- newWorldRenderContext uiWorld program
	--lc <- newLightContext

	--let world = game^.gameLogicWorld

	--vc <- newVisibilityContext (world^.wCollisionManager) (0, 0)

	return RenderContext
		{ _rcPlayerId = playerId
		, _rcMainProgram = program
		--, _rcWorldRenderContext = wrc
		--, _rcLightContext = lc
		--, _rcVisibilityContext = vc
		--, _rcUIRenderContext = uirc
		}

clearWindow :: GLFW.Window -> IO ()
clearWindow window = do
	GL.clearColor $= GL.Color4 0 0 0 1
	logGL "clearWindow: clearColor"
	GL.clear [GL.ColorBuffer]
	logGL "clearWindow: clear"
	(width, height) <- GLFW.getFramebufferSize window
	GL.viewport $= (GL.Position 0 0, GL.Size (fromIntegral width) (fromIntegral height))
	logGL "clearWindow: viewport"

render :: GLFW.Window -> RenderContext -> Camera -> IO Camera
render window rc cam = do
	-- update camera in every frame for now
	--(width, height) <- GLFW.getFramebufferSize window
	clearWindow window

	--logGL "render: set current program"

	--let world = rc^.rcWorldRenderContext.wrcWorld

	--let Just (x, y) = world^?wLayerObject "CObjectLayer" ("Player" ++ show (rc^.rcPlayerId))._Just.roPos
	let newCam = cam -- cameraUpdatePosition cam (-x) (-y)

	let newRc = rc -- & rcLightContext.lcLights._head.lightPosition .~ (-x, y)

	--GL.stencilTest $= GL.Enabled
	--GL.stencilFunc $= (GL.Never, 1, 255)
	--GL.stencilOp $= (GL.OpReplace, GL.OpKeep, GL.OpKeep)
	--GL.clearStencil $= 0
	--GL.stencilMask $= 255
	--GL.clear [GL.StencilBuffer]

	--visCtxt <- updateVisibilityContext (newRc^.rcVisibilityContext) (x, y)
	--renderVisibilityContext visCtxt newCam

	--GL.stencilMask $= 0
	--GL.stencilFunc $= (GL.Equal, 0, 255)
	--GL.stencilFunc $= (GL.Equal, 1, 255)

	--GL.currentProgram $= Just (newRc^.rcMainProgram)
	--programSetViewProjection (newRc^.rcMainProgram) newCam
	--updateWorldRenderContext (newRc^.rcWorldRenderContext)
	--renderWorldRenderContext (newRc^.rcMainProgram) (newRc^.rcWorldRenderContext) (rc^.rcPlayerId)

	--GL.stencilTest $= GL.Disabled

	--let uirc = newRc^.rcUIRenderContext
	--GL.currentProgram $= Just (newRc^.rcMainProgram)
	--programSetViewProjection (newRc^.rcMainProgram) (cameraSetOriginTopLeft newCam)
	--updateWorldRenderContext uirc
	--renderWorldRenderContext (newRc^.rcMainProgram) uirc 0

	return newCam


	--updateLightContext (newRc^.rcLightContext)
	--renderLightContext (newRc^.rcLightContext) newCam
	--where
	--	object name = mapLayers.traverse._ObjectLayer.layerObjects.traverse.objectsByName name
