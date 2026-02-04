import React, { useEffect, useRef, useState } from 'react';
import { useThree, useFrame } from '@react-three/fiber';
// @ts-ignore
import { WebGPURenderer } from 'three/webgpu';
import * as THREE from 'three';

import { VisionaryInitializer } from '../utils/visionary-initializer';
import { GaussianThreeJSRenderer } from '../visionary-core-copy/app/GaussianThreeJSRenderer';
import { ModelManager } from '../visionary-core-copy/app/managers/model-manager';
import { FileLoader } from '../visionary-core-copy/app/managers/file-loader';
import { ONNXManager } from '../visionary-core-copy/app/managers/onnx-manager';
import { GaussianLoader } from '../visionary-core-copy/app/managers/gaussian-loader';
import { VisionaryProvider } from './VisionaryContext';

interface VisionaryRendererProps {
	children?: React.ReactNode;
}

export const VisionaryRenderer: React.FC<VisionaryRendererProps> = ({
	children,
}) => {
	const { gl, scene, camera } = useThree();
	const [isReady, setIsReady] = useState(false);

	// Services
	const rendererRef = useRef<GaussianThreeJSRenderer | null>(null);
	const modelManagerRef = useRef<ModelManager | null>(null);
	const gaussianLoaderRef = useRef<GaussianLoader | null>(null);

	useEffect(() => {
		let isMounted = true;
		let rendererInstance: GaussianThreeJSRenderer | null = null;

		const initVisionary = async () => {
			const initializer = VisionaryInitializer.getInstance();

			try {
				// Check if already initialized in another effect call
				if (rendererRef.current) {
					console.log(
						'[VisionaryRenderer] Renderer already exists, skipping init.',
					);
					return;
				}

				// Set debug flags globally
				(globalThis as any).GS_DEBUG_FLAG = true;
				(globalThis as any).GS_VIDEO_EXPORT_DEBUG = true;

				// 1. Initialize WebGPU Environment
				await initializer.initializeWithExistingRenderer(
					gl as unknown as WebGPURenderer,
					{
						debugMode: true,
					},
				);

				if (!isMounted) return;

				// Check again after await
				if (rendererRef.current) {
					console.log(
						'[VisionaryRenderer] Renderer created during await, skipping.',
					);
					return;
				}

				// 2. Initialize Managers
				const modelManager = new ModelManager();
				const fileLoader = new FileLoader(modelManager, {
					onProgress: (show, text, pct) => {
						console.log(`[Loading] ${text} ${pct}%`);
					},
					onError: (msg) => console.error(`[Error] ${msg}`),
				});
				const onnxManager = new ONNXManager(modelManager);
				const gaussianLoader = new GaussianLoader(fileLoader, onnxManager);

				modelManagerRef.current = modelManager;
				gaussianLoaderRef.current = gaussianLoader;

				// 3. Initialize Gaussian Renderer
				const gaussianRenderer = new GaussianThreeJSRenderer(
					gl as unknown as WebGPURenderer,
					scene,
					[], // Start with empty models, they will be added via Splat components
				);
				await gaussianRenderer.init();

				if (!isMounted) {
					console.log(
						`[VisionaryRenderer] Component unmounted during initialization. Disposing renderer #${gaussianRenderer.instanceId}.`,
					);
					gaussianRenderer.dispose();
					return;
				}

				// Final check before assigning
				if (rendererRef.current) {
					console.log(
						`[VisionaryRenderer] Renderer exists (#${(rendererRef.current as any).instanceId}). Disposing new one (#${gaussianRenderer.instanceId}).`,
					);
					gaussianRenderer.dispose();
					return;
				}

				rendererInstance = gaussianRenderer;
				rendererRef.current = gaussianRenderer;
				console.log(
					`[VisionaryRenderer] Adding renderer #${gaussianRenderer.instanceId} to scene ${scene.uuid}`,
				);
				scene.add(gaussianRenderer);

				setIsReady(true);
				console.log('Visionary System Initialized');
			} catch (error) {
				console.error('Failed to initialize Visionary:', error);
			}
		};

		if (gl && !rendererRef.current) {
			initVisionary();
		}

		return () => {
			isMounted = false;
			if (rendererInstance) {
				console.log(
					`[VisionaryRenderer] Disposing renderer instance #${(rendererInstance as any).instanceId} from scene ${scene.uuid}`,
				);
				// Call dispose method on renderer
				if (typeof (rendererInstance as any).dispose === 'function') {
					(rendererInstance as any).dispose();
				} else {
					scene.remove(rendererInstance);
				}

				// TODO: dispose managers/renderers if needed
				// rendererRef.current.dispose();
			}
			if (rendererRef.current === rendererInstance) {
				rendererRef.current = null;
			}
		};
	}, [gl, scene]);

	// Hook into the render loop
	useFrame(({ gl, scene, camera }) => {
		if (rendererRef.current && isReady) {
			// Check if we need to manually trigger any updates
			// GaussianThreeJSRenderer mostly handles itself via onBeforeRender,
			// but we might want to expose hooks here.

			// Note: If using autoDepthMode, we might need to ensure depth capture happens
			// But GaussianThreeJSRenderer usually handles this.

			// New architecture: GaussianThreeJSRenderer handles Three.js rendering internally
			// This automatically captures depth from the full scene
			// This replaces the standard renderer.render(scene, camera) if we want depth integration
			rendererRef.current.renderThreeScene(camera);

			// Explicitly draw splats on top
			rendererRef.current.drawSplats(gl, scene, camera);
		}
	});

	return (
		<VisionaryProvider
			value={{
				renderer: rendererRef.current,
				gaussianLoader: gaussianLoaderRef.current,
				modelManager: modelManagerRef.current,
				isReady,
			}}
		>
			{children}
		</VisionaryProvider>
	);
};
