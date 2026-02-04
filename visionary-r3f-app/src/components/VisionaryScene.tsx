import React, { useEffect, useRef, useState } from 'react';
import { useThree, useFrame } from '@react-three/fiber';
// @ts-ignore
import { WebGPURenderer } from 'three/webgpu';
import * as THREE from 'three';

import { VisionaryInitializer } from '../utils/visionary-initializer';
import { GaussianThreeJSRenderer } from '../visionary-core-copy/app/GaussianThreeJSRenderer';
import { GaussianModel } from '../visionary-core-copy/app/GaussianModel';
import { App } from '../visionary-core-copy/app/app';

// Mock App for GaussianModel dependencies if needed, or we might need to adjust GaussianModel
// Actually GaussianModel seems to rely on App for some things? Let's check GaussianModel.ts later.
// For now, let's assume we can instantiate GaussianModel directly or via a manager.

export const VisionaryScene: React.FC = () => {
	const { gl, scene, camera } = useThree();
	const [isReady, setIsReady] = useState(false);
	const rendererRef = useRef<GaussianThreeJSRenderer | null>(null);

	useEffect(() => {
		const initVisionary = async () => {
			const initializer = VisionaryInitializer.getInstance();

			// Ensure WebGPU environment is initialized
			// We pass the current R3F renderer to it
			try {
				await initializer.initializeWithExistingRenderer(
					gl as unknown as WebGPURenderer,
					{
						debugMode: true,
					},
				);
				setIsReady(true);
			} catch (error) {
				console.error('Failed to initialize Visionary:', error);
			}
		};

		if (gl) {
			initVisionary();
		}
	}, [gl]);

	useEffect(() => {
		if (!isReady) return;

		// Initialize GaussianThreeJSRenderer
		const gaussianRenderer = new GaussianThreeJSRenderer(
			gl as unknown as WebGPURenderer,
			scene,
			[], // Start with empty models
		);

		rendererRef.current = gaussianRenderer;
		scene.add(gaussianRenderer);

		// Example: Load a model
		// We might need to use the ONNXManager or ModelManager from visionary-core
		// For now, let's try to load the default ONNX model if possible,
		// or expose a way to load models.

		// Since GaussianThreeJSRenderer manages the rendering of GaussianModels,
		// we need to create a GaussianModel and add it.
		// However, GaussianModel usually wraps a PointCloud.

		// Let's rely on the App logic or replicate it slightly here.
		// Ideally, we should port the App's loading logic to a React hook or similar.

		// For this task, we will just set up the renderer and log success.
		console.log('Visionary GaussianThreeJSRenderer added to scene');

		return () => {
			scene.remove(gaussianRenderer);
			// dispose logic if any
		};
	}, [isReady, gl, scene]);

	useFrame(() => {
		if (rendererRef.current) {
			// If GaussianThreeJSRenderer needs per-frame updates
			// It seems it inherits from Mesh, so Three.js handles it,
			// but we might need to call specific update methods if they exist.

			// Check if we need to manually trigger depth capture or things like that
			rendererRef.current.renderThreeScene(camera);
		}
	});

	return null; // This component doesn't render DOM, it manipulates the scene
};
