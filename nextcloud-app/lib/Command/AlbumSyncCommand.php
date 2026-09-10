<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Command;
use OCA\ApplePhotosConnector\Service\AlbumSyncOrchestrator;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\{InputArgument,InputInterface};
use Symfony\Component\Console\Output\OutputInterface;
final class AlbumSyncCommand extends Command {
    public function __construct(private AlbumSyncOrchestrator $orchestrator){parent::__construct('apple-photos-connector:album:sync');}
    protected function configure():void{$this->setDescription('Synchronize inventoried Apple albums additively to Photos')->addArgument('sourceId',InputArgument::REQUIRED)->addArgument('userId',InputArgument::REQUIRED);}
    protected function execute(InputInterface $i,OutputInterface $o):int{try{$r=$this->orchestrator->sync((string)$i->getArgument('sourceId'),(string)$i->getArgument('userId'));foreach($r as$k=>$v)$o->writeln($k.': '.(is_array($v)?json_encode($v,JSON_UNESCAPED_SLASHES):$v));return $r['errors']?Command::FAILURE:Command::SUCCESS;}catch(\Throwable $e){$o->writeln('<error>'.$e->getMessage().'</error>');return Command::FAILURE;}}
}
