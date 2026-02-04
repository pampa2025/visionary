// @ts-ignore
import { WebGPURenderer } from 'three/webgpu';
import { initOrtEnvironment } from '../visionary-core-copy/config/ort-config';

type ProgressCallback = (
	stage: string,
	progress: number,
	message: string,
) => void;

export class VisionaryInitializer {
	private static instance: VisionaryInitializer;
	private initialized = false;
	private threeRenderer: WebGPURenderer | null = null;
	private progressCallback: ProgressCallback | null = null;

	private constructor() {}

	public static getInstance(): VisionaryInitializer {
		if (!VisionaryInitializer.instance) {
			VisionaryInitializer.instance = new VisionaryInitializer();
		}
		return VisionaryInitializer.instance;
	}

	public setProgressCallback(callback: ProgressCallback) {
		this.progressCallback = callback;
	}

	private updateProgress(stage: string, progress: number, message: string) {
		if (this.progressCallback) {
			this.progressCallback(stage, progress, message);
		}
		console.log(
			`[VisionaryInit] [${stage}] ${Math.round(progress * 100)}% - ${message}`,
		);
	}

	/**
	 * 初始化Visionary核心环境
	 * 支持传入现有的Three.js WebGPURenderer
	 */
	async initializeWithExistingRenderer(
		renderer: WebGPURenderer,
		config: {
			enablePrecision?: 'high' | 'medium' | 'low';
			debugMode?: boolean;
		} = {},
	): Promise<WebGPURenderer> {
		if (this.threeRenderer === renderer) {
			return this.threeRenderer;
		}

		try {
			this.threeRenderer = renderer;

			// 阶段1: 检查WebGPU支持
			this.updateProgress('checking_webgpu', 0.1, 'Checking WebGPU support...');
			if (!navigator.gpu) {
				throw new Error(
					'WebGPU not available. Ensure you are using Chrome 113+ with #enable-unsafe-webgpu flag.',
				);
			}

			// 阶段2: 加载ONNX运行时
			this.updateProgress('loading_onnx', 0.2, 'Loading ONNX Runtime...');
			await this.loadONNXRuntime();

			// Wait for renderer to be ready (it might be initializing backend)
			// @ts-ignore
			await renderer.init();

			// Configure ONNX to use Three.js device
			// @ts-ignore
			const backend = renderer.backend;
			const threeDevice = (backend as any).device as GPUDevice;

			if (typeof window !== 'undefined' && (window as any).ort) {
				const ort = (window as any).ort;
				if (ort.env && ort.env.webgpu) {
					ort.env.webgpu.device = threeDevice;
					console.log('Configured ONNX to use Three.js WebGPU device');
				}
			}

			this.updateProgress('ready', 1, 'WebGPU environment initialized!');
			return renderer;
		} catch (error: any) {
			this.updateProgress(
				'error',
				0,
				`Initialization failed: ${error.message}`,
			);
			throw error;
		}
	}

	private async loadONNXRuntime(modelPath?: string): Promise<void> {
		try {
			// Configure ONNX environment paths
			// WASM files should be in public/ort/
			initOrtEnvironment('/ort/');

			// Dynamic import of ONNX runtime
			// Using onnxruntime-web/webgpu
			// @ts-ignore
			const ort = await import('onnxruntime-web/webgpu');

			if (typeof window !== 'undefined') {
				(window as any).ort = ort;

				// Ensure configuration is applied immediately
				if (ort.env && ort.env.wasm) {
					ort.env.wasm.wasmPaths = '/ort/';
					ort.env.wasm.numThreads = 1;
				}
			}

			console.log('ONNX runtime loaded successfully');
		} catch (error: any) {
			console.warn('Failed to load ONNX runtime:', error);
			// Log but allow proceeding, maybe fallback to non-ONNX mode if possible
			// But if ONNX is strictly required, this might be an issue.
			throw error;
		}
	}

	public getRenderer(): WebGPURenderer | null {
		return this.threeRenderer;
	}
}
