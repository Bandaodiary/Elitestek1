"""C34 source-fault stimuli: same assertions, candidate production sources."""
import run_r2_credit_rgb2_host_fault_probe as retained
from run_r2_ring_rgb2_host_probe import SOURCES


if __name__=='__main__':
    retained.SOURCES=SOURCES
    retained.TOP='tb_c1_r2_ring_rgb2_host_faults'
    retained.PREFIX='C1_R2_RING_RGB2_HOST_FAULT_'
    retained.main()
