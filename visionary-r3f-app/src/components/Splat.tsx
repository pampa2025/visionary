import React, { useEffect, useRef, useState } from 'react';
import * as THREE from 'three';
import { useVisionary } from './VisionaryContext';
import { GaussianModel } from '../visionary-core-copy/app/GaussianModel';
// @ts-ignore
import { WebGPURenderer } from 'three/webgpu';
import { useThree } from '@react-three/fiber';

interface SplatProps {
	src: string;
	position?: [number, number, number];
	rotation?: [number, number, number];
	scale?: [number, number, number] | number;
	visible?: boolean;
	name?: string;
	formatHint?: string; // 'ply', 'splat', 'ksplat', 'onnx', etc.
}

export const Splat: React.FC<SplatProps> = ({
	src,
	position = [0, 0, 0],
	rotation = [0, 0, 0],
	scale = 1,
	visible = true,
	name,
	formatHint,
}) => {
	const { gaussianLoader, renderer, isReady } = useVisionary();
	const { gl } = useThree();
	const [model, setModel] = useState<GaussianModel | null>(null);
	const modelRef = useRef<GaussianModel | null>(null);

	useEffect(() => {
		if (!isReady || !gaussianLoader || !renderer) return;

		let isMounted = true;

		const loadModel = async () => {
			try {
				console.log(`Loading Splat: ${src}`);
				const loadedModel = await gaussianLoader.createFromGaussian(
					gl as unknown as WebGPURenderer,
					src,
					{ name: name || src.split('/').pop() },
					formatHint,
				);

				if (!isMounted) {
					// Dispose if unmounted during load
					// loadedModel.dispose();
					return;
				}

				// Set initial transforms
				loadedModel.position.set(...position);
				loadedModel.rotation.set(...rotation);
				if (typeof scale === 'number') {
					loadedModel.scale.set(scale, scale, scale);
				} else {
					loadedModel.scale.set(...scale);
				}
				loadedModel.visible = visible;

				// Add to renderer
				if (renderer) {
					console.log(
						`[Splat] Adding model ${loadedModel.name} to renderer (ID: ${(renderer as any).instanceId}). Model visible: ${loadedModel.visible}`,
					);
					renderer.addModel(loadedModel);
				} else {
					console.error('[Splat] Renderer is null when trying to add model!');
				}

				// Add to scene graph (GaussianModel is an Object3D)
				// Actually GaussianThreeJSRenderer manages the rendering,
				// but adding it to the scene graph might be useful for raycasting/transform controls
				// if GaussianThreeJSRenderer doesn't already do it?
				// Wait, GaussianThreeJSRenderer iterates over `gaussianModels`.
				// It does NOT rely on them being children of the scene.
				// However, for R3F to handle transforms declaratively, we might want to wrap it in a primitive?
				// Or we can just manage the Object3D properties manually.

				setModel(loadedModel);
				modelRef.current = loadedModel;
			} catch (error) {
				console.error(`Failed to load splat ${src}:`, error);
			}
		};

		loadModel();

		return () => {
			isMounted = false;
			if (modelRef.current && renderer) {
				// Remove from renderer
				renderer.removeModel(modelRef.current);
				setModel(null);
				modelRef.current = null;
			}
		};
	}, [src, isReady, gaussianLoader, renderer, gl]); // Re-load if src changes

	// Update transforms on prop changes
	useEffect(() => {
		if (model) {
			model.position.set(...position);
			model.rotation.set(...rotation);
			if (typeof scale === 'number') {
				model.scale.set(scale, scale, scale);
			} else {
				model.scale.set(...scale);
			}
			model.visible = visible;
			model.updateMatrixWorld(); // Ensure matrix is updated
		}
	}, [position, rotation, scale, visible, model]);

	// If we want to support nesting or attaching children to the splat (like a label),
	// we could render <primitive object={model} /> but GaussianModel is already an Object3D.
	// However, since it's not added to the scene graph by default (only to renderer's list),
	// we might want to consider if we SHOULD add it to the scene graph.
	// GaussianThreeJSRenderer usually iterates its own list.

	return null;
};
