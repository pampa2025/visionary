import { useThree, extend, ReactThreeFiber } from '@react-three/fiber';
import './App.css';
import { Box, OrbitControls } from '@react-three/drei';
import { AsyncWebGPUCanvas } from './components/AsyncWebGPUCanvas';
import { StatsMonitor } from './components/StatsMonitor';

function App() {
	return (
		<div style={{ width: '100vw', height: '100vh' }}>
			<AsyncWebGPUCanvas camera={{ position: [0, 0, 5] }}>
				<ambientLight intensity={0.5} />
				<spotLight position={[10, 10, 10]} angle={0.15} penumbra={1} />
				<pointLight position={[-10, -10, -10]} />
				<gridHelper args={[10, 10]} />
				<Box position={[-1.2, 0, 0]} />
				<Box position={[1.2, 0, 0]} />
				<OrbitControls />
				<StatsMonitor />
			</AsyncWebGPUCanvas>
		</div>
	);
}

export default App;
